/*
 * Copyright (C) 2020
 *
 * Author: Morgan MacKechnie
 *
 * This file is part of ocserv.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>
 */

#include <config.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE
#endif

#ifdef HAVE_SAML
#include "saml.h"
#include <lasso/lasso.h>
#include <lasso/xml/saml-2.0/samlp2_response.h>
#include <lasso/xml/saml-2.0/saml2_audience_restriction.h>
#include "lasso_compat.h"
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <apr_time.h>
#include <ctype.h>
#include <fcntl.h>    /* for open() and O_* flags */
#include <errno.h>    /* for strerror() */
#include <limits.h>
#include <unistd.h>   /* for unlink() */

/* inih is bundled with ocserv */
#include "inih/ini.h"

#define SAML_DEFAULT_CLOCK_SKEW_TOLERANCE 60
#define SAML_MAX_CLOCK_SKEW_TOLERANCE 3600
#define SAML_DEFAULT_REPLAY_CACHE_TTL 300
#define SAML_MAX_REPLAY_CACHE_TTL 86400
#define SAML_SP_METADATA_RUNTIME_FILE "/run/ocserv/spmeta.xml"
#define SAML_IDP_SSO_HTTP_REDIRECT "SingleSignOnService HTTP-Redirect"
#define SAML_BEARER_CONFIRMATION_METHOD "urn:oasis:names:tc:SAML:2.0:cm:bearer"
#define SAML_SHA1_ALGORITHM_SUFFIX "sha1"

static void saml_exit_invalid_ulong_option(const char *name, unsigned long max)
{
	fprintf(stderr,
		"SAML: Invalid %s value. Expected integer between 0 and %lu.\n",
		name, max);
	exit(EXIT_FAILURE);
}

/* Helper function to parse bracket options - similar to expand_brackets_string */
static unsigned int saml_expand_brackets(void *pool, const char *str,
                                          subcfg_val_st out[MAX_SUBOPTIONS])
{
	char *p, *p2, *p3;
	unsigned int len, len2;
	unsigned int pos = 0, finish = 0;

	if (str == NULL)
		return 0;

	p = strchr(str, '[');
	if (p == NULL) {
		return 0;
	}
	p++;
	while (isspace((unsigned char)*p))
		p++;

	do {
		p2 = strchr(p, '=');
		if (p2 == NULL) {
			fprintf(stderr, "SAML: error parsing %s\n", str);
			exit(EXIT_FAILURE);
		}
		len = p2 - p;

		p2++;
		while (isspace((unsigned char)*p2))
			p2++;

		p3 = strchr(p2, ',');
		if (p3 == NULL) {
			p3 = strchr(p2, ']');
			if (p3 == NULL) {
				fprintf(stderr, "SAML: error parsing %s\n", str);
				exit(EXIT_FAILURE);
			}
			finish = 1;
		}
		len2 = p3 - p2;

		if (len > 0) {
			while (isspace((unsigned char)p[len - 1]))
				len--;
		}
		if (len2 > 0) {
			while (isspace((unsigned char)p2[len2 - 1]))
				len2--;
		}

		out[pos].name = talloc_strndup(pool, p, len);
		out[pos].value = talloc_strndup(pool, p2, len2);
		pos++;
		p = p2 + len2;
		while (isspace((unsigned char)*p) || *p == ',')
			p++;
	} while (finish == 0 && pos < MAX_SUBOPTIONS);

	return pos;
}

/* Parse SAML configuration string and return config structure */
void *saml_get_brackets_string(void *pool, struct perm_cfg_st *config,
			       const char *str)
{
	subcfg_val_st vals[MAX_SUBOPTIONS];
	saml_cfg_st *additional;
	unsigned int vals_size, i;

	/* Allocate saml_cfg_st structure (must be done before parsing) */
	additional = talloc_zero(pool, saml_cfg_st);
	if (additional == NULL) {
		fprintf(stderr, "SAML: allocation failure\n");
		exit(EXIT_FAILURE);
	}

	vals_size = saml_expand_brackets(pool, str, vals);

	for (i = 0; i < vals_size; i++) {
		if (strcasecmp(vals[i].name, "config") == 0) {
			additional->config = talloc_strdup(pool, vals[i].value);
		}
	}

	/* Validate required config field */
	if (additional->config == NULL) {
		fprintf(stderr, "SAML: No configuration file specified: %s\n", str);
		exit(EXIT_FAILURE);
	}

	return additional;
}

static int saml_ulong_option_is_invalid(const char *value, char *endptr,
					unsigned long result,
					unsigned long max)
{
	return errno != 0 || endptr == value || *endptr != '\0' ||
	    result > max;
}

static unsigned long saml_parse_ulong_option(const char *name,
					     const char *value,
					     unsigned long max)
{
	char *endptr;
	unsigned long result;

	errno = 0;
	result = strtoul(value, &endptr, 10);
	if (saml_ulong_option_is_invalid(value, endptr, result, max))
		saml_exit_invalid_ulong_option(name, max);

	return result;
}

static void saml_set_ini_defaults(saml_cfg_st *config, void *pool)
{
	config->pool = pool;
	config->clock_skew_tolerance = SAML_DEFAULT_CLOCK_SKEW_TOLERANCE;
	config->replay_cache_ttl = SAML_DEFAULT_REPLAY_CACHE_TTL;
}

static int cfg_ini_handler(void *_config, const char *section, const char *name,
			   const char *_value);

static void saml_parse_ini_file(saml_cfg_st *config)
{
	int rc;

	rc = ini_parse(config->config, cfg_ini_handler, config);
	if (rc < 0) {
		fprintf(stderr, "SAML: Cannot load configuration file: %s\n",
			config->config);
		exit(EXIT_FAILURE);
	}
}

static void saml_validate_ini_required_fields(saml_cfg_st *config)
{
	if (config->spmeta != NULL && config->spkey != NULL &&
	    config->spcert != NULL && config->idpmeta != NULL)
		return;

	fprintf(stderr,
		"SAML: Missing required configuration field in %s.\n",
		config->config);
	exit(EXIT_FAILURE);
}

/* INI config handler - uses talloc via pool stored in config struct */
static int cfg_ini_handler(void *_config, const char *section, const char *name,
			   const char *_value)
{
	saml_cfg_st *config = _config;
	void *pool = config->pool;

	(void)section;

	if (strcmp(name, "sp-metadata-file") == 0) {
		config->spmeta = talloc_strdup(pool, _value);
	} else if (strcmp(name, "sp-keyfile") == 0) {
		config->spkey = talloc_strdup(pool, _value);
	} else if (strcmp(name, "sp-cert") == 0) {
		config->spcert = talloc_strdup(pool, _value);
	} else if (strcmp(name, "idp-metadata-file") == 0) {
		config->idpmeta = talloc_strdup(pool, _value);
	} else if (strcmp(name, "idp-cert") == 0) {
		config->idpcert = talloc_strdup(pool, _value);
	} else if (strcmp(name, "clock-skew-tolerance") == 0) {
		config->clock_skew_tolerance =
		    saml_parse_ulong_option(name, _value,
					    SAML_MAX_CLOCK_SKEW_TOLERANCE);
	} else if (strcmp(name, "replay-cache-ttl") == 0) {
		config->replay_cache_ttl =
		    saml_parse_ulong_option(name, _value,
					    SAML_MAX_REPLAY_CACHE_TTL);
	}
	return (1);
}

static void saml_load_ini_config(saml_cfg_st *config, void *pool)
{
	/* Store pool in config so cfg_ini_handler can use talloc */
	saml_set_ini_defaults(config, pool);
	saml_parse_ini_file(config);
	saml_validate_ini_required_fields(config);
}

static void saml_load_idp_name(struct saml_vhost_ctx *vctx)
{
	GList *idp_list;

	idp_list = g_hash_table_get_keys(vctx->server->providers);
	if (idp_list == NULL || idp_list->data == NULL) {
		fprintf(stderr,
			"SAML: No identity provider found in configuration. Check metadata.\n");
		g_object_unref(vctx->server);
		exit(1);
	}

	vctx->config->idpname = g_strdup((char *)idp_list->data);
	g_list_free(idp_list);
}

static void saml_load_idp_endpoints(struct saml_vhost_ctx *vctx)
{
	saml_cfg_st *config = vctx->config;

	config->idp_sso_dest_url =
	    lasso_server_get_endpoint_url_by_id(vctx->server, config->idpname,
						SAML_IDP_SSO_HTTP_REDIRECT);
	config->acs_url =
	    lasso_provider_get_assertion_consumer_service_url((void *)vctx->
							      server, NULL);
}

static void saml_load_sp_entity_id(struct saml_vhost_ctx *vctx)
{
	saml_cfg_st *config = vctx->config;
	LassoProvider *sp;

	/* Extract SP Entity ID - LassoServer inherits from LassoProvider */
	sp = LASSO_PROVIDER(vctx->server);
	if (sp && sp->ProviderID)
		config->sp_entity_id = g_strdup(sp->ProviderID);
}

static void saml_validate_idp_runtime_config(saml_cfg_st *config)
{
	if (config->idp_sso_dest_url != NULL && config->acs_url != NULL &&
	    config->sp_entity_id != NULL)
		return;

	fprintf(stderr,
		"SAML: Missing IdP SSO URL, ACS URL, or SP Entity ID in metadata.\n");
	exit(EXIT_FAILURE);
}

static void saml_load_idp_runtime_config(struct saml_vhost_ctx *vctx)
{
	saml_load_idp_name(vctx);
	saml_load_idp_endpoints(vctx);
	saml_load_sp_entity_id(vctx);
	saml_validate_idp_runtime_config(vctx->config);
}

static void saml_init_lasso_server(struct saml_vhost_ctx *vctx)
{
	saml_cfg_st *config = vctx->config;
	lasso_error_t ret;

	ret = lasso_init();
	if (ret != 0) {
		fprintf(stderr,
			"SAML: lasso_init() failed: [%i] %s\n",
			ret, lasso_strerror(ret));
		exit(1);
	}

	lasso_set_default_signature_method(LASSO_SIGNATURE_METHOD_RSA_SHA256);

	vctx->server = lasso_server_new(config->spmeta, config->spkey, NULL,
					 config->spcert);
	if (vctx->server == NULL) {
		fprintf(stderr,
			"SAML: Error initializing Lasso server object. Check configuration. It's almost always the metadata.\n");
		exit(1);
	}

	ret = lasso_server_add_provider(vctx->server, LASSO_PROVIDER_ROLE_IDP,
					  config->idpmeta, NULL, config->idpcert);
	if (ret != 0) {
		fprintf(stderr,
			"SAML: Error loading identity provider. Check configuration.\n");
		exit(1);
	}

	saml_load_idp_runtime_config(vctx);
}

static void saml_copy_sp_metadata(const char *source_file)
{
	const char *dest_file = SAML_SP_METADATA_RUNTIME_FILE;
	FILE *fptrSrc = NULL, *fptrDest = NULL;
	int fd;
	char buf[4096];
	size_t nread;

	/* We need saml sp metadata in a predictable location for worker processes
	 * to serve upon request. Use /run/ocserv/ which is a tmpfs mount and
	 * avoids /tmp symlink/cleanup issues.
	 * Security: Use unlink() + open() with O_NOFOLLOW and O_EXCL to prevent
	 * symlink attacks that could overwrite arbitrary system files. */
	fptrSrc = fopen(source_file, "r");
	if (fptrSrc == NULL) {
		fprintf(stderr, "SAML: Cannot open SP metadata file: %s\n",
			source_file);
		return;
	}

	/* First unlink to remove any existing symlink or file */
	unlink(dest_file);

	/* Then create with O_NOFOLLOW to reject symlinks, O_CREAT|O_EXCL for atomic creation */
	fd = open(dest_file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
	if (fd < 0) {
		fprintf(stderr, "SAML: Cannot create %s: %s (may already exist or be a symlink)\n",
			dest_file, strerror(errno));
		fclose(fptrSrc);
		return;
	}

	fptrDest = fdopen(fd, "w");
	if (fptrDest == NULL) {
		fprintf(stderr, "SAML: Cannot open file descriptor for writing\n");
		close(fd);
		fclose(fptrSrc);
		return;
	}

	while ((nread = fread(buf, 1, sizeof(buf), fptrSrc)) > 0) {
		if (fwrite(buf, 1, nread, fptrDest) != nread) {
			fprintf(stderr, "SAML: Error writing SP metadata to %s\n",
				dest_file);
			break;
		}
	}

	fclose(fptrSrc);
	fclose(fptrDest);
}

/* Parse the saml subconfig and construct a Lasso server object. */
static void saml_vhost_init(void **_vctx, void *pool, void *additional)
{
	saml_cfg_st *config = additional;
	struct saml_vhost_ctx *vctx;

	saml_load_ini_config(config, pool);

	vctx = talloc_zero(pool, struct saml_vhost_ctx);
	if (vctx == NULL) {
		fprintf(stderr, "SAML: allocation failure\n");
		exit(EXIT_FAILURE);
	}

	vctx->config = config;
	vctx->replay_cache =
	    g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
	if (vctx->replay_cache == NULL) {
		fprintf(stderr, "SAML: allocation failure\n");
		exit(EXIT_FAILURE);
	}
	g_mutex_init(&vctx->replay_cache_mutex);

	saml_init_lasso_server(vctx);

	*_vctx = (void *)vctx;
	saml_copy_sp_metadata(config->spmeta);
}

static void saml_auth_ctx_free(struct saml_ctx_st *ctx)
{
	if (ctx == NULL)
		return;

	if (ctx->login)
		lasso_login_destroy(ctx->login);
	if (ctx->request_id)
		g_free(ctx->request_id);
	talloc_free(ctx);
}

static int saml_prepare_authn_request(struct saml_ctx_st *ctx,
				      struct saml_vhost_ctx *vctx)
{
	int ret;

	ret = lasso_login_init_authn_request(ctx->login, vctx->config->idpname,
					   LASSO_HTTP_METHOD_REDIRECT);
	if (ret != 0) {
		fprintf(stderr, "SAML: Lasso error: [%i] %s\n", ret,
			lasso_strerror(ret));
		return -1;
	}

	ctx->request =
	    LASSO_SAMLP2_AUTHN_REQUEST(LASSO_PROFILE(ctx->login)->request);
	if (ctx->request->NameIDPolicy == NULL) {
		fprintf(stderr, "SAML: Error creating login request\n");
		return -1;
	}

	ctx->request->ForceAuthn = FALSE;
	ctx->request->IsPassive = FALSE;
	ctx->request->NameIDPolicy->AllowCreate = TRUE;

	if (LASSO_SAMLP2_REQUEST_ABSTRACT(ctx->request)->Destination == NULL) {
		lasso_assign_string(LASSO_SAMLP2_REQUEST_ABSTRACT
				    (ctx->request)->Destination,
				    vctx->config->idp_sso_dest_url);
	}

	LASSO_SAMLP2_REQUEST_ABSTRACT(ctx->request)->Consent
	    = g_strdup(LASSO_SAML2_CONSENT_IMPLICIT);

	if (LASSO_SAMLP2_REQUEST_ABSTRACT(ctx->request)->ID == NULL) {
		fprintf(stderr, "SAML: AuthnRequest ID was not generated\n");
		return -1;
	}
	ctx->request_id =
	    g_strdup(LASSO_SAMLP2_REQUEST_ABSTRACT(ctx->request)->ID);
	if (ctx->request_id == NULL) {
		fprintf(stderr, "SAML: allocation failure\n");
		return -1;
	}

	ret = lasso_login_build_authn_request_msg(ctx->login);
	if (ret != 0) {
		fprintf(stderr, "SAML: Failed building authn request: [%i] %s\n",
			ret, lasso_strerror(ret));
		return -1;
	}

	return 0;
}

/* Initialise a login object */
static int saml_auth_init(void **_ctx, void *pool, void *_vctx,
			  const common_auth_init_st * info)
{
	struct saml_ctx_st *ctx;
	struct saml_vhost_ctx *vctx = _vctx;

	ctx = talloc_zero(pool, struct saml_ctx_st);
	if (ctx == NULL)
		return ERR_AUTH_FAIL;

	ctx->login = lasso_login_new(vctx->server);
	if (ctx->login == NULL) {
		fprintf(stderr, "SAML: lasso_login_new() failed\n");
		talloc_free(ctx);
		return ERR_AUTH_FAIL;
	}

	if (saml_prepare_authn_request(ctx, vctx) != 0) {
		saml_auth_ctx_free(ctx);
		return ERR_AUTH_FAIL;
	}

	ctx->vctx = vctx;

	*_ctx = (void *)ctx;

	return (ERR_AUTH_CONTINUE);
}

static int saml_auth_msg(void *_ctx, void *pool, passwd_msg_st * pst)
{
	struct saml_ctx_st *ctx = _ctx;
	char *redirect_url;

	redirect_url = LASSO_PROFILE(ctx->login)->msg_url;

	pst->msg_str = talloc_strdup(pool, (char *)redirect_url);

	pst->counter = 0;

	return 0;
}

static int saml_timestamp_two_digits(const char *timestamp, size_t pos)
{
	return (timestamp[pos] - '0') * 10 + (timestamp[pos + 1] - '0');
}

static int saml_is_leap_year(int year)
{
	return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

static int saml_days_in_month(int year, int month)
{
	static const int days[] = {
		31, 28, 31, 30, 31, 30,
		31, 31, 30, 31, 30, 31
	};

	if (month == 2 && saml_is_leap_year(year))
		return 29;

	return days[month - 1];
}

static int saml_validate_timestamp_length(const char *timestamp, size_t len)
{
	if (timestamp == NULL || (len != 20 && (len < 22 || len > 27))) {
		fprintf(stderr, "SAML: Invalid timestamp length.\n");
		return -1;
	}

	return 0;
}

static int saml_validate_timestamp_separators(const char *timestamp)
{
	if (timestamp[4] != '-' || timestamp[7] != '-' ||
	    timestamp[10] != 'T' || timestamp[13] != ':' ||
	    timestamp[16] != ':') {
		fprintf(stderr, "SAML: Invalid timestamp separator format.\n");
		return -1;
	}

	return 0;
}

static int saml_validate_timestamp_utc_suffix(const char *timestamp, size_t len)
{
	size_t frac_len;

	if (len == 20) {
		if (timestamp[19] != 'Z') {
			fprintf(stderr, "SAML: Timestamp was not in UTC.\n");
			return -1;
		}
		return 0;
	}

	if (timestamp[19] != '.' || timestamp[len - 1] != 'Z') {
		fprintf(stderr, "SAML: Invalid fractional timestamp format.\n");
		return -1;
	}

	frac_len = len - 21;
	if (frac_len == 0 || frac_len > 6) {
		fprintf(stderr, "SAML: Invalid timestamp fractional precision.\n");
		return -1;
	}

	return 0;
}

static int saml_timestamp_is_format_char(size_t pos, size_t len)
{
	return pos == 4 || pos == 7 || pos == 10 || pos == 13 ||
	    pos == 16 || pos == 19 || pos == len - 1;
}

static int saml_validate_timestamp_digits(const char *timestamp, size_t len)
{
	size_t i;

	for (i = 0; i < len; i++) {
		if (saml_timestamp_is_format_char(i, len))
			continue;
		if (!isdigit((unsigned char)timestamp[i])) {
			fprintf(stderr, "SAML: Timestamp contains non-digit data.\n");
			return -1;
		}
	}

	return 0;
}

static int saml_validate_timestamp_format(const char *timestamp, size_t len)
{
	if (saml_validate_timestamp_length(timestamp, len) != 0)
		return -1;

	if (saml_validate_timestamp_separators(timestamp) != 0)
		return -1;

	if (saml_validate_timestamp_utc_suffix(timestamp, len) != 0)
		return -1;

	if (saml_validate_timestamp_digits(timestamp, len) != 0)
		return -1;

	return 0;
}

static void saml_fill_timestamp_exp(apr_time_exp_t *time_exp,
				    const char *timestamp, size_t len)
{
	size_t i;
	size_t frac_end;

	memset(time_exp, 0, sizeof(*time_exp));

	time_exp->tm_sec = saml_timestamp_two_digits(timestamp, 17);
	time_exp->tm_min = saml_timestamp_two_digits(timestamp, 14);
	time_exp->tm_hour = saml_timestamp_two_digits(timestamp, 11);
	time_exp->tm_mday = saml_timestamp_two_digits(timestamp, 8);
	time_exp->tm_mon = saml_timestamp_two_digits(timestamp, 5) - 1;
	time_exp->tm_year = (timestamp[0] - '0') * 1000 +
	    (timestamp[1] - '0') * 100 + (timestamp[2] - '0') * 10 +
	    (timestamp[3] - '0') - 1900;

	time_exp->tm_usec = 0;
	if (len > 20) {
		frac_end = len - 1;
		for (i = 20; i < frac_end; i++)
			time_exp->tm_usec =
			    time_exp->tm_usec * 10 + timestamp[i] - '0';
		for (i = frac_end - 20; i < 6; i++)
			time_exp->tm_usec *= 10;
	}
}

static int saml_validate_timestamp_date_range(const apr_time_exp_t *time_exp)
{
	int year = time_exp->tm_year + 1900;
	int month = time_exp->tm_mon + 1;

	if (year < 1970 || time_exp->tm_mon < 0 || time_exp->tm_mon > 11 ||
	    time_exp->tm_mday < 1)
		return -1;

	if (time_exp->tm_mday > saml_days_in_month(year, month))
		return -1;

	return 0;
}

static int saml_validate_timestamp_time_range(const apr_time_exp_t *time_exp)
{
	if (time_exp->tm_hour < 0 || time_exp->tm_hour > 23 ||
	    time_exp->tm_min < 0 || time_exp->tm_min > 59 ||
	    time_exp->tm_sec < 0 || time_exp->tm_sec > 59)
		return -1;

	return 0;
}

static int saml_validate_timestamp_range(const apr_time_exp_t *time_exp,
					 const char *timestamp)
{
	(void)timestamp;

	if (saml_validate_timestamp_date_range(time_exp) != 0 ||
	    saml_validate_timestamp_time_range(time_exp) != 0) {
		fprintf(stderr, "SAML: Timestamp values out of range.\n");
		return -1;
	}

	return 0;
}

static apr_time_t saml_parse_timestamp(const char *timestamp)
{
	size_t len;
	apr_time_exp_t time_exp;
	apr_time_t res;
	apr_status_t rc;

	len = strlen(timestamp);
	if (saml_validate_timestamp_format(timestamp, len) != 0)
		return 0;

	saml_fill_timestamp_exp(&time_exp, timestamp, len);
	if (saml_validate_timestamp_range(&time_exp, timestamp) != 0)
		return 0;

	rc = apr_time_exp_gmt_get(&res, &time_exp);
	if (rc != APR_SUCCESS) {
		fprintf(stderr, "SAML: Error converting timestamp \"%s\".\n",
			timestamp);
		return 0;
	}

	return res;
}

static int saml_validate_time_bound(const char *timestamp, apr_time_t now,
				    unsigned long tolerance_us, int is_not_before,
				    const char *invalid_msg,
				    const char *range_msg)
{
	apr_time_t t;

	if (timestamp == NULL)
		return 0;

	t = saml_parse_timestamp(timestamp);
	if (t == 0) {
		fprintf(stderr, "%s", invalid_msg);
		return -1;
	}

	if (is_not_before) {
		if (t - tolerance_us <= now)
			return 0;
	} else if (now < t + tolerance_us) {
		return 0;
	}

	fprintf(stderr, "%s", range_msg);
	return -1;
}

static int saml_require_nonempty(const char *value, const char *msg)
{
	if (value != NULL && value[0] != '\0')
		return 0;

	fprintf(stderr, "%s", msg);
	return -1;
}

static LassoSaml2Subject *saml_get_valid_subject(LassoSaml2Assertion *assertion)
{
	if (assertion->Subject == NULL) {
		fprintf(stderr, "SAML: Subject is required.\n");
		return NULL;
	} else if (!LASSO_IS_SAML2_SUBJECT(assertion->Subject)) {
		fprintf(stderr, "SAML: Wrong type of Subject node.\n");
		return NULL;
	}

	return assertion->Subject;
}

static LassoSaml2SubjectConfirmation *
saml_get_valid_subject_confirmation(LassoSaml2Subject *subject)
{
	if (subject->SubjectConfirmation == NULL) {
		fprintf(stderr, "SAML: SubjectConfirmation is required.\n");
		return NULL;
	} else if (!LASSO_IS_SAML2_SUBJECT_CONFIRMATION
		(subject->SubjectConfirmation)) {
		fprintf(stderr, "SAML: Wrong type of SubjectConfirmation node.\n");
		return NULL;
	}

	return subject->SubjectConfirmation;
}

static int saml_validate_subject_confirmation_method(
	LassoSaml2SubjectConfirmation *sc)
{
	if (sc->Method == NULL ||
	    strcmp(sc->Method, SAML_BEARER_CONFIRMATION_METHOD) != 0) {
		fprintf(stderr, "SAML: Invalid Method in SubjectConfirmation.\n");
		return -1;
	}

	return 0;
}

static LassoSaml2SubjectConfirmationData *
saml_get_valid_subject_confirmation_data(LassoSaml2SubjectConfirmation *sc)
{
	LassoSaml2SubjectConfirmationData *scd;

	scd = sc->SubjectConfirmationData;
	if (scd == NULL) {
		fprintf(stderr,
			"SAML: SubjectConfirmationData is required for bearer confirmation.\n");
		return NULL;
	} else if (!LASSO_IS_SAML2_SUBJECT_CONFIRMATION_DATA(scd)) {
		fprintf(stderr,
			"SAML: Wrong type of SubjectConfirmationData node.\n");
		return NULL;
	}

	return scd;
}

static LassoSaml2SubjectConfirmationData *
saml_get_bearer_subject_confirmation_data(LassoSaml2Assertion *assertion)
{
	LassoSaml2Subject *subject;
	LassoSaml2SubjectConfirmation *sc;
	LassoSaml2SubjectConfirmationData *scd;

	subject = saml_get_valid_subject(assertion);
	if (subject == NULL)
		return NULL;

	sc = saml_get_valid_subject_confirmation(subject);
	if (sc == NULL)
		return NULL;

	if (saml_validate_subject_confirmation_method(sc) != 0)
		return NULL;

	scd = saml_get_valid_subject_confirmation_data(sc);
	if (scd == NULL)
		return NULL;

	return scd;
}

static int saml_validate_subject_required_fields(
	LassoSaml2SubjectConfirmationData *scd)
{
	if (saml_require_nonempty(scd->InResponseTo,
				  "SAML: InResponseTo is required in SubjectConfirmationData.\n") != 0)
		return -1;

	if (saml_require_nonempty(scd->NotOnOrAfter,
				  "SAML: NotOnOrAfter is required in SubjectConfirmationData.\n") != 0)
		return -1;

	if (saml_require_nonempty(scd->Recipient,
				  "SAML: Recipient is required in SubjectConfirmationData.\n") != 0)
		return -1;

	return 0;
}

static int saml_validate_subject_binding(
	LassoSaml2SubjectConfirmationData *scd,
	const char *url, const char *request_id)
{
	if (request_id == NULL || strcmp(scd->InResponseTo, request_id) != 0) {
		fprintf(stderr,
			"SAML: SubjectConfirmationData InResponseTo did not match request ID.\n");
		return -1;
	}

	if (strcmp(scd->Recipient, url) != 0) {
		fprintf(stderr,
			"SAML: Wrong Recipient in SubjectConfirmationData.\n");
		return -1;
	}

	return 0;
}

static int saml_validate_subject_time_bounds(
	LassoSaml2SubjectConfirmationData *scd,
	unsigned long tolerance_us)
{
	apr_time_t now = apr_time_now();

	if (saml_validate_time_bound(scd->NotBefore, now, tolerance_us, 1,
				     "SAML: Invalid timestamp in NotBefore in SubjectConfirmationData.\n",
				     "SAML: NotBefore in SubjectConfirmationData was in the future.\n") != 0)
		return -1;

	return saml_validate_time_bound(scd->NotOnOrAfter, now, tolerance_us, 0,
					"SAML: Invalid timestamp in NotOnOrAfter in SubjectConfirmationData.\n",
					"SAML: NotOnOrAfter in SubjectConfirmationData was in the past.\n");
}

static int saml_validate_subject_data(
	LassoSaml2SubjectConfirmationData *scd,
	const char *url, const char *request_id,
	unsigned long tolerance_us, apr_time_t *not_on_or_after)
{
	if (saml_validate_subject_required_fields(scd) != 0)
		return -1;

	if (saml_validate_subject_binding(scd, url, request_id) != 0)
		return -1;

	if (saml_validate_subject_time_bounds(scd, tolerance_us) != 0)
		return -1;

	if (not_on_or_after)
		*not_on_or_after = saml_parse_timestamp(scd->NotOnOrAfter);

	return 0;
}

static int saml_validate_subject(LassoSaml2Assertion *assertion,
				 const char *url, const char *request_id,
				 unsigned long tolerance_us,
				 apr_time_t *not_on_or_after,
				 LassoSaml2SubjectConfirmationData **out_scd)
{
	LassoSaml2SubjectConfirmationData *scd;

	scd = saml_get_bearer_subject_confirmation_data(assertion);
	if (scd == NULL)
		return -1;

	if (saml_validate_subject_data(scd, url, request_id, tolerance_us,
				       not_on_or_after) != 0)
		return -1;

	if (out_scd)
		*out_scd = scd;

	return 0;
}

/* Validate Assertion Conditions NotBefore/NotOnOrAfter time constraints */
static int saml_validate_conditions(LassoSaml2Assertion *assertion,
					  unsigned long tolerance_us)
{
	apr_time_t now;

	if (assertion->Conditions == NULL) {
		fprintf(stderr, "SAML: Assertion Conditions are required.\n");
		return -1;
	}

	if (assertion->Conditions->NotOnOrAfter == NULL ||
	    assertion->Conditions->NotOnOrAfter[0] == '\0') {
		fprintf(stderr,
			"SAML: Conditions NotOnOrAfter is required.\n");
		return -1;
	}

	now = apr_time_now();

	if (saml_validate_time_bound(assertion->Conditions->NotBefore, now,
				     tolerance_us, 1,
				     "SAML: Invalid timestamp in Conditions NotBefore.\n",
				     "SAML: Conditions NotBefore is in the future.\n") != 0)
		return -1;

	if (saml_validate_time_bound(assertion->Conditions->NotOnOrAfter, now,
				     tolerance_us, 0,
				     "SAML: Invalid timestamp in Conditions NotOnOrAfter.\n",
				     "SAML: Conditions NotOnOrAfter is in the past.\n") != 0)
		return -1;

	return 0;
}

/* Validate AudienceRestriction contains this SP's Entity ID.
 * In lasso 2.9.0, AudienceRestriction is in Conditions->AudienceRestriction (GList),
 * and Audience is a char* field (single URI) on LassoSaml2AudienceRestriction. */
static int saml_audience_restriction_matches(gpointer data,
					      const char *sp_entity_id)
{
	LassoSaml2AudienceRestriction *ar;

	if (!LASSO_IS_SAML2_AUDIENCE_RESTRICTION(data))
		return 0;

	ar = LASSO_SAML2_AUDIENCE_RESTRICTION(data);
	return ar->Audience && strcmp(ar->Audience, sp_entity_id) == 0;
}

static int saml_audience_restrictions_contain(GList *ar_list,
					       const char *sp_entity_id)
{
	for (; ar_list != NULL; ar_list = ar_list->next) {
		if (saml_audience_restriction_matches(ar_list->data,
						      sp_entity_id))
			return 1;
	}

	return 0;
}

static GList *saml_get_required_audience_restrictions(
	LassoSaml2Assertion *assertion,
	const char *sp_entity_id)
{
	GList *ar_list;

	if (assertion->Conditions == NULL || sp_entity_id == NULL ||
	    sp_entity_id[0] == '\0') {
		fprintf(stderr, "SAML: Cannot validate AudienceRestriction.\n");
		return NULL;
	}

	ar_list = assertion->Conditions->AudienceRestriction;
	if (ar_list == NULL) {
		fprintf(stderr, "SAML: AudienceRestriction is required.\n");
		return NULL;
	}

	return ar_list;
}

static int saml_validate_audience(LassoSaml2Assertion *assertion,
				  const char *sp_entity_id)
{
	GList *ar_list;

	ar_list = saml_get_required_audience_restrictions(assertion, sp_entity_id);
	if (ar_list == NULL)
		return -1;

	if (saml_audience_restrictions_contain(ar_list, sp_entity_id))
		return 0;

	fprintf(stderr,
		"SAML: SP Entity ID '%s' not found in AudienceRestriction.\n",
		sp_entity_id);
	return -1;
}

static int saml_store_name_id(struct saml_ctx_st *ctx)
{
	const char *name_id;

	if (LASSO_PROFILE(ctx->login)->nameIdentifier == NULL) {
		fprintf(stderr,
			"SAML: No acceptable name identifier found in SAML 2.0 response.\n");
		return -1;
	}

	name_id = LASSO_SAML2_NAME_ID(LASSO_PROFILE(ctx->login)->nameIdentifier)->content;
	if (name_id == NULL || name_id[0] == '\0') {
		fprintf(stderr, "SAML: NameID content is empty or NULL.\n");
		return -1;
	}

	strncpy(ctx->username, name_id, sizeof(ctx->username) - 1);
	ctx->username[sizeof(ctx->username) - 1] = '\0';
	return 0;
}

static int saml_validate_response_destination(LassoSamlp2Response *response,
					      const char *acs_url)
{
	if (response->parent.ID == NULL || response->parent.ID[0] == '\0') {
		fprintf(stderr, "SAML: Response ID is required.\n");
		return -1;
	}

	if (response->parent.Destination == NULL ||
	    response->parent.Destination[0] == '\0') {
		fprintf(stderr, "SAML: Response Destination is required.\n");
		return -1;
	}

	if (strcmp(response->parent.Destination, acs_url) == 0)
		return 0;

	fprintf(stderr,
		"SAML: Invalid Destination on Response. Expected '%s', got '%s'\n",
		acs_url, response->parent.Destination);
	return -1;
}

static int saml_validate_response_in_response_to(LassoSamlp2Response *response,
						 const char *request_id)
{
	if (response->parent.InResponseTo == NULL ||
	    response->parent.InResponseTo[0] == '\0') {
		fprintf(stderr, "SAML: Response InResponseTo is required.\n");
		return -1;
	}

	if (request_id == NULL ||
	    strcmp(response->parent.InResponseTo, request_id) != 0) {
		fprintf(stderr,
			"SAML: Response InResponseTo did not match request ID.\n");
		return -1;
	}

	return 0;
}

static LassoSaml2Assertion *saml_get_single_assertion(LassoSamlp2Response *response)
{
	guint assertion_count;
	LassoSaml2Assertion *assertion;

	assertion_count = g_list_length(response->Assertion);
	if (assertion_count == 0) {
		fprintf(stderr, "SAML: No assertion in response.\n");
		return NULL;
	}

	if (assertion_count > 1) {
		fprintf(stderr, "SAML: More than one assertion in response.\n");
		return NULL;
	}

	assertion = g_list_first(response->Assertion)->data;
	if (!LASSO_IS_SAML2_ASSERTION(assertion)) {
		fprintf(stderr, "SAML: Wrong type of assertion node.\n");
		return NULL;
	}
	if (assertion->ID == NULL || assertion->ID[0] == '\0') {
		fprintf(stderr, "SAML: Assertion ID is required.\n");
		return NULL;
	}

	return assertion;
}

static int saml_xml_algorithm_uses_sha1(const xmlChar *algorithm)
{
	char *lower;
	int uses_sha1;

	if (algorithm == NULL)
		return 0;

	lower = g_ascii_strdown((const char *)algorithm, -1);
	if (lower == NULL)
		return 0;

	uses_sha1 = g_str_has_suffix(lower, SAML_SHA1_ALGORITHM_SUFFIX);
	g_free(lower);
	return uses_sha1;
}

static int saml_xml_is_signature_or_digest_method(xmlNode *node)
{
	if (node->type != XML_ELEMENT_NODE)
		return 0;

	return xmlStrcmp(node->name, BAD_CAST "SignatureMethod") == 0 ||
	    xmlStrcmp(node->name, BAD_CAST "DigestMethod") == 0;
}

static int saml_xml_method_node_uses_sha1(xmlNode *node)
{
	xmlChar *algorithm;
	int uses_sha1;

	if (!saml_xml_is_signature_or_digest_method(node))
		return 0;

	algorithm = xmlGetProp(node, BAD_CAST "Algorithm");
	uses_sha1 = saml_xml_algorithm_uses_sha1(algorithm);
	if (algorithm)
		xmlFree(algorithm);

	return uses_sha1;
}

static int saml_xml_reject_sha1_node(xmlNode *node)
{
	for (; node != NULL; node = node->next) {
		if (saml_xml_method_node_uses_sha1(node)) {
			fprintf(stderr,
				"SAML: Rejected SHA-1 XML signature or digest algorithm.\n");
			return -1;
		}

		if (saml_xml_reject_sha1_node(node->children) != 0)
			return -1;
	}

	return 0;
}

static guchar *saml_decode_response(const char *saml_response,
				    gsize *decoded_len)
{
	guchar *decoded;

	if (saml_response == NULL || saml_response[0] == '\0')
		return NULL;

	decoded = g_base64_decode(saml_response, decoded_len);
	if (decoded == NULL || *decoded_len == 0) {
		fprintf(stderr, "SAML: Failed decoding SAML response.\n");
		if (decoded)
			g_free(decoded);
		return NULL;
	}

	return decoded;
}

static xmlDocPtr saml_parse_decoded_response(guchar *decoded,
					     gsize decoded_len)
{
	xmlDocPtr doc;

	doc = xmlReadMemory((const char *)decoded, decoded_len, "saml-response.xml",
			    NULL, XML_PARSE_NONET | XML_PARSE_NOERROR |
				  XML_PARSE_NOWARNING);
	if (doc == NULL) {
		fprintf(stderr, "SAML: Failed parsing decoded SAML response XML.\n");
		return NULL;
	}

	return doc;
}

static int saml_reject_sha1_xml_algorithms(const char *saml_response)
{
	guchar *decoded;
	gsize decoded_len;
	xmlDocPtr doc;
	int rc = -1;

	decoded = saml_decode_response(saml_response, &decoded_len);
	if (decoded == NULL)
		return -1;

	doc = saml_parse_decoded_response(decoded, decoded_len);
	if (doc == NULL)
		goto cleanup;

	rc = saml_xml_reject_sha1_node(xmlDocGetRootElement(doc));
	xmlFreeDoc(doc);

 cleanup:
	g_free(decoded);
	return rc;
}

static int saml_reject_sha1_signature(LassoSaml2Assertion *assertion)
{
	/* Reject SHA-1 signature algorithms per NIST SP 800-131A Rev. 2
	 * and OWASP SAML Security Cheat Sheet recommendations.
	 * lasso 2.9.0 may have internal protections, but we enforce
	 * at application level for defense-in-depth.
	 * LassoSignatureMethod enum values: RSA_SHA1=1, DSA_SHA1=2, HMAC_SHA1=3 */
	if (assertion->sign_method != LASSO_SIGNATURE_METHOD_RSA_SHA1 &&
	    assertion->sign_method != LASSO_SIGNATURE_METHOD_DSA_SHA1 &&
	    assertion->sign_method != LASSO_SIGNATURE_METHOD_HMAC_SHA1)
		return 0;

	fprintf(stderr,
		"SAML: Rejected SHA-1 signature algorithm (enum value %d)\n",
		assertion->sign_method);
	return -1;
}

static void saml_replay_cache_prune_locked(struct saml_vhost_ctx *vctx,
					   apr_time_t now)
{
	GHashTableIter iter;
	gpointer key, value;
	apr_time_t *expires_at;

	g_hash_table_iter_init(&iter, vctx->replay_cache);
	while (g_hash_table_iter_next(&iter, &key, &value)) {
		expires_at = value;
		if (expires_at == NULL || *expires_at <= now)
			g_hash_table_iter_remove(&iter);
	}
}

static char *saml_replay_cache_make_key(const char *prefix, const char *id)
{
	if (id == NULL || id[0] == '\0') {
		fprintf(stderr, "SAML: Missing identifier for replay cache.\n");
		return NULL;
	}

	return g_strdup_printf("%s:%s", prefix, id);
}

static int saml_replay_cache_key_is_available(struct saml_vhost_ctx *vctx,
					      const char *key)
{
	if (key == NULL) {
		fprintf(stderr, "SAML: allocation failure\n");
		return 0;
	}

	if (g_hash_table_contains(vctx->replay_cache, key)) {
		fprintf(stderr, "SAML: Replayed SAML identifier rejected.\n");
		return 0;
	}

	return 1;
}

static int saml_replay_cache_keys_are_available(struct saml_vhost_ctx *vctx,
						char **keys,
						size_t key_count)
{
	size_t i;

	for (i = 0; i < key_count; i++) {
		if (!saml_replay_cache_key_is_available(vctx, keys[i]))
			return 0;
	}

	return 1;
}

static int saml_replay_cache_insert_key_locked(struct saml_vhost_ctx *vctx,
					       char **key,
					       apr_time_t expires_at)
{
	apr_time_t *stored_expires_at;

	stored_expires_at = g_new(apr_time_t, 1);
	if (stored_expires_at == NULL) {
		fprintf(stderr, "SAML: allocation failure\n");
		return -1;
	}

	*stored_expires_at = expires_at;
	g_hash_table_insert(vctx->replay_cache, *key, stored_expires_at);
	*key = NULL;
	return 0;
}

static int saml_replay_cache_store_keys_locked(struct saml_vhost_ctx *vctx,
					       char **keys,
					       size_t key_count,
					       apr_time_t expires_at)
{
	size_t i;

	if (!saml_replay_cache_keys_are_available(vctx, keys, key_count))
		return -1;

	for (i = 0; i < key_count; i++) {
		if (saml_replay_cache_insert_key_locked(vctx, &keys[i],
							expires_at) != 0)
			return -1;
	}

	return 0;
}

static void saml_replay_cache_free_keys(char **keys, size_t key_count)
{
	size_t i;

	for (i = 0; i < key_count; i++) {
		if (keys[i])
			g_free(keys[i]);
	}
}

static int saml_replay_cache_keys_are_complete(char **keys, size_t key_count)
{
	size_t i;

	for (i = 0; i < key_count; i++) {
		if (keys[i] == NULL) {
			fprintf(stderr, "SAML: allocation failure\n");
			return 0;
		}
	}

	return 1;
}

static int saml_replay_cache_prepare_keys(char **keys,
					  LassoSamlp2Response *response,
					  LassoSaml2Assertion *assertion,
					  LassoSaml2SubjectConfirmationData *scd)
{
	keys[0] = saml_replay_cache_make_key("response", response->parent.ID);
	keys[1] = saml_replay_cache_make_key("assertion", assertion->ID);
	keys[2] = saml_replay_cache_make_key("in-response-to", scd->InResponseTo);

	if (!saml_replay_cache_keys_are_complete(keys, 3))
		return -1;

	return 0;
}

static int saml_replay_cache_store(struct saml_ctx_st *ctx,
				   LassoSamlp2Response *response,
				   LassoSaml2Assertion *assertion,
				   LassoSaml2SubjectConfirmationData *scd,
				   apr_time_t expires_at)
{
	struct saml_vhost_ctx *vctx = ctx->vctx;
	apr_time_t now = apr_time_now();
	char *keys[3] = { NULL, NULL, NULL };
	int rc = -1;

	if (expires_at <= now)
		expires_at =
		    now + (apr_time_t)vctx->config->replay_cache_ttl *
		    APR_USEC_PER_SEC;

	g_mutex_lock(&vctx->replay_cache_mutex);
	saml_replay_cache_prune_locked(vctx, now);

	if (saml_replay_cache_prepare_keys(keys, response, assertion, scd) != 0)
		goto cleanup;
	if (saml_replay_cache_store_keys_locked(vctx, keys, 3,
						expires_at) != 0)
		goto cleanup;

	rc = 0;

 cleanup:
	saml_replay_cache_free_keys(keys, 3);
	g_mutex_unlock(&vctx->replay_cache_mutex);
	return rc;
}

static void saml_auth_fail(struct saml_ctx_st *ctx)
{
	if (ctx->login) {
		lasso_login_destroy(ctx->login);
		ctx->login = NULL;
	}
}

struct saml_validated_response {
	LassoSamlp2Response *response;
	LassoSaml2Assertion *assertion;
	LassoSaml2SubjectConfirmationData *scd;
	apr_time_t replay_expires_at;
};

static int saml_process_authn_response(struct saml_ctx_st *ctx,
				       const char *saml_response)
{
	int rc;

	rc = lasso_login_process_authn_response_msg(ctx->login,
						    (gchar *)saml_response);
	if (rc != 0) {
		fprintf(stderr, "SAML: Error processing authn response\n");
		fprintf(stderr, "SAML: Lasso error: [%i] %s\n", rc,
			lasso_strerror(rc));
		return -1;
	}

	return 0;
}

static LassoSamlp2Response *saml_get_valid_response_node(
	struct saml_ctx_st *ctx)
{
	LassoSamlp2Response *response;

	response = LASSO_SAMLP2_RESPONSE(LASSO_PROFILE(ctx->login)->response);
	if (response == NULL || !LASSO_IS_SAMLP2_RESPONSE(response)) {
		fprintf(stderr, "SAML: Wrong type of response node.\n");
		return NULL;
	}

	return response;
}

static int saml_validate_response_binding(struct saml_ctx_st *ctx,
					  LassoSamlp2Response *response)
{
	if (saml_validate_response_destination(response,
					       ctx->vctx->config->acs_url) != 0)
		return -1;

	return saml_validate_response_in_response_to(response, ctx->request_id);
}

static apr_time_t saml_min_positive_time(apr_time_t first, apr_time_t second)
{
	if (first == 0)
		return second;
	if (second == 0)
		return first;
	return first < second ? first : second;
}

static apr_time_t saml_calculate_replay_expires_at(
	apr_time_t subject_expires_at,
	apr_time_t conditions_expires_at,
	unsigned long tolerance_us)
{
	apr_time_t replay_expires_at;

	replay_expires_at = saml_min_positive_time(subject_expires_at,
						   conditions_expires_at);
	if (replay_expires_at > 0)
		replay_expires_at += tolerance_us;

	return replay_expires_at;
}

static int saml_validate_assertion_context(
	struct saml_ctx_st *ctx,
	LassoSaml2Assertion *assertion,
	unsigned long tolerance_us,
	struct saml_validated_response *validated)
{
	apr_time_t subject_expires_at = 0;
	apr_time_t conditions_expires_at;

	if (saml_validate_conditions(assertion, tolerance_us) != 0)
		return -1;
	conditions_expires_at =
	    saml_parse_timestamp(assertion->Conditions->NotOnOrAfter);

	if (saml_validate_audience(assertion, ctx->vctx->config->sp_entity_id) != 0)
		return -1;

	if (saml_validate_subject(assertion, ctx->vctx->config->acs_url,
				  ctx->request_id, tolerance_us,
				  &subject_expires_at, &validated->scd) != 0)
		return -1;

	validated->replay_expires_at =
	    saml_calculate_replay_expires_at(subject_expires_at,
					     conditions_expires_at,
					     tolerance_us);
	return 0;
}

static int saml_validate_processed_response(
	struct saml_ctx_st *ctx,
	struct saml_validated_response *validated)
{
	unsigned long tolerance_us;

	validated->response = saml_get_valid_response_node(ctx);
	if (validated->response == NULL)
		return -1;

	if (saml_validate_response_binding(ctx, validated->response) != 0)
		return -1;

	validated->assertion = saml_get_single_assertion(validated->response);
	if (validated->assertion == NULL)
		return -1;

	if (saml_reject_sha1_signature(validated->assertion) != 0)
		return -1;

	tolerance_us = ctx->vctx->config->clock_skew_tolerance * 1000000;
	return saml_validate_assertion_context(ctx, validated->assertion,
					       tolerance_us, validated);
}

static int saml_validate_authn_response(
	struct saml_ctx_st *ctx,
	const char *saml_response,
	struct saml_validated_response *validated)
{
	if (saml_process_authn_response(ctx, saml_response) != 0)
		return -1;

	if (saml_store_name_id(ctx) != 0)
		return -1;

	return saml_validate_processed_response(ctx, validated);
}

static int saml_auth_pass(void *_ctx, const char *saml_response,
			  unsigned pass_len)
{
	struct saml_ctx_st *ctx = _ctx;
	struct saml_validated_response validated = { 0 };

	(void)pass_len;

	if (saml_reject_sha1_xml_algorithms(saml_response) != 0)
		goto auth_fail;

	if (saml_validate_authn_response(ctx, saml_response, &validated) != 0)
		goto auth_fail;

	if (saml_replay_cache_store(ctx, validated.response, validated.assertion,
				    validated.scd,
				    validated.replay_expires_at) != 0)
		goto auth_fail;

	return 0;

 auth_fail:
	saml_auth_fail(ctx);
	return ERR_AUTH_FAIL;
}

static int saml_auth_user(void *_ctx, char *username, int username_size)
{
	struct saml_ctx_st *ctx = _ctx;

	strlcpy(username, ctx->username, username_size);

	return 0;
}

void saml_auth_deinit(void *_ctx)
{
	saml_auth_ctx_free(_ctx);
}

static void saml_replay_cache_deinit(struct saml_vhost_ctx *vctx)
{
	if (vctx->replay_cache == NULL)
		return;

	g_mutex_lock(&vctx->replay_cache_mutex);
	g_hash_table_destroy(vctx->replay_cache);
	vctx->replay_cache = NULL;
	g_mutex_unlock(&vctx->replay_cache_mutex);
	g_mutex_clear(&vctx->replay_cache_mutex);
}

static void saml_server_deinit(struct saml_vhost_ctx *vctx)
{
	if (vctx->server)
		g_object_unref(vctx->server);
}

static void saml_runtime_config_deinit(saml_cfg_st *config)
{
	if (config == NULL)
		return;

	if (config->idpname)
		g_free(config->idpname);
	if (config->sp_entity_id)
		g_free(config->sp_entity_id);
	if (config->idp_sso_dest_url)
		g_free(config->idp_sso_dest_url);
	if (config->acs_url)
		g_free(config->acs_url);
}

static void saml_vhost_deinit(void *_vctx)
{
	struct saml_vhost_ctx *vctx = _vctx;

	if (vctx) {
		saml_replay_cache_deinit(vctx);
		saml_server_deinit(vctx);
		saml_runtime_config_deinit(vctx->config);
	}
	lasso_shutdown();
}

const struct auth_mod_st saml_auth_funcs = {
	.type = AUTH_TYPE_SAML,
	.vhost_init = saml_vhost_init,
	.vhost_deinit = saml_vhost_deinit,
	.auth_init = saml_auth_init,
	.auth_deinit = saml_auth_deinit,
	.auth_msg = saml_auth_msg,
	.auth_pass = saml_auth_pass,
	.auth_user = saml_auth_user,
	.auth_group = NULL,
	.group_list = NULL,
	.allows_retries = 1
};

#endif /* HAVE_SAML */
