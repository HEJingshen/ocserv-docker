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
#include <unistd.h>   /* for unlink() */

/* inih is bundled with ocserv */
#include "inih/ini.h"

#define SAML_DEFAULT_CLOCK_SKEW_TOLERANCE 60
#define SAML_SP_METADATA_RUNTIME_FILE "/run/ocserv/spmeta.xml"
#define SAML_IDP_SSO_HTTP_REDIRECT "SingleSignOnService HTTP-Redirect"
#define SAML_BEARER_CONFIRMATION_METHOD "urn:oasis:names:tc:SAML:2.0:cm:bearer"

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

/* INI config handler - uses talloc via pool stored in config struct */
static int cfg_ini_handler(void *_config, const char *section, const char *name,
			   const char *_value)
{
	saml_cfg_st *config = _config;
	void *pool = config->pool;

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
		config->clock_skew_tolerance = atol(_value);
	}
	return (1);
}

static void saml_load_ini_config(saml_cfg_st *config, void *pool)
{
	/* Store pool in config so cfg_ini_handler can use talloc */
	config->pool = pool;
	ini_parse(config->config, cfg_ini_handler, config);

	/* Set default clock skew tolerance if not configured (60 seconds) */
	if (config->clock_skew_tolerance == 0)
		config->clock_skew_tolerance =
		    SAML_DEFAULT_CLOCK_SKEW_TOLERANCE;
}

static void saml_load_idp_runtime_config(struct saml_vhost_ctx *vctx)
{
	saml_cfg_st *config = vctx->config;
	GList *idp_list;
	LassoProvider *sp;

	idp_list = g_hash_table_get_keys(vctx->server->providers);
	if (idp_list == NULL || idp_list->data == NULL) {
		fprintf(stderr,
			"SAML: No identity provider found in configuration. Check metadata.\n");
		g_object_unref(vctx->server);
		exit(1);
	}
	config->idpname = g_strdup((char *)idp_list->data);
	g_list_free(idp_list);
	idp_list = NULL;
	config->idp_sso_dest_url =
	    lasso_server_get_endpoint_url_by_id(vctx->server, config->idpname,
						SAML_IDP_SSO_HTTP_REDIRECT);
	config->acs_url =
	    lasso_provider_get_assertion_consumer_service_url((void *)vctx->
							      server, NULL);

	/* Extract SP Entity ID - LassoServer inherits from LassoProvider */
	sp = LASSO_PROVIDER(vctx->server);
	if (sp && sp->ProviderID)
		config->sp_entity_id = g_strdup(sp->ProviderID);
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

static const char *saml_timestamp_expected_char(size_t pos, char c)
{
	switch (pos) {
	case 4:
	case 7:
		return c == '-' ? NULL : "'-'";
	case 10:
		return c == 'T' ? NULL : "'T'";
	case 13:
	case 16:
		return c == ':' ? NULL : "':'";
	case 19:
		return c == '.' ? NULL : "'.'";
	default:
		return (c >= '0' && c <= '9') ? NULL : "a digit";
	}
}

static int saml_validate_timestamp_format(const char *timestamp, size_t len)
{
	size_t i;
	const char *expected;

	if (len < 20) {
		fprintf(stderr, "SAML: Invalid length of timestamp: \"%s\".\n",
			timestamp);
		return -1;
	}

	for (i = 0; i < len - 1; i++) {
		expected = saml_timestamp_expected_char(i, timestamp[i]);
		if (expected != NULL) {
			fprintf(stderr,
				"SAML: Invalid character in timestamp at position %i.\n"
				"Expected %s, got '%c'. Full timestamp: \"%s\"\n",
				(int)i, expected, timestamp[i], timestamp);
			return -1;
		}
	}

	if (timestamp[len - 1] != 'Z') {
		fprintf(stderr,
			"SAML: Timestamp wasn't in UTC (did not end with 'Z').\n"
			"Full timestamp: \"%s\"\n", timestamp);
		return -1;
	}

	return 0;
}

static int saml_timestamp_two_digits(const char *timestamp, size_t pos)
{
	return (timestamp[pos] - '0') * 10 + (timestamp[pos + 1] - '0');
}

static void saml_parse_timestamp_usec(apr_time_exp_t *time_exp,
				      const char *timestamp, size_t len)
{
	size_t end;
	size_t i;

	time_exp->tm_usec = 0;
	if (len > 20) {
		end = len > 27 ? 27 : len;
		end -= 1;
		for (i = 20; i < end; i++) {
			time_exp->tm_usec =
			    time_exp->tm_usec * 10 + timestamp[i] - '0';
		}
		for (i = end; i < 26; i++)
			time_exp->tm_usec *= 10;
	}
}

static void saml_fill_timestamp_exp(apr_time_exp_t *time_exp,
				    const char *timestamp, size_t len)
{
	memset(time_exp, 0, sizeof(*time_exp));

	saml_parse_timestamp_usec(time_exp, timestamp, len);
	time_exp->tm_sec = saml_timestamp_two_digits(timestamp, 17);
	time_exp->tm_min = saml_timestamp_two_digits(timestamp, 14);
	time_exp->tm_hour = saml_timestamp_two_digits(timestamp, 11);
	time_exp->tm_mday = saml_timestamp_two_digits(timestamp, 8);
	time_exp->tm_mon = saml_timestamp_two_digits(timestamp, 5) - 1;
	time_exp->tm_year = (timestamp[0] - '0') * 1000 +
	    (timestamp[1] - '0') * 100 + (timestamp[2] - '0') * 10 +
	    (timestamp[3] - '0') - 1900;
}

static int saml_validate_timestamp_range(const apr_time_exp_t *time_exp,
					 const char *timestamp)
{
	if (time_exp->tm_mon < 0 || time_exp->tm_mon > 11 ||
	    time_exp->tm_mday < 1 || time_exp->tm_mday > 31 ||
	    time_exp->tm_hour < 0 || time_exp->tm_hour > 23 ||
	    time_exp->tm_min < 0 || time_exp->tm_min > 59 ||
	    time_exp->tm_sec < 0 || time_exp->tm_sec > 60) {
		fprintf(stderr,
			"SAML: Timestamp values out of range: \"%s\".\n",
			timestamp);
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

static int saml_validate_subject(LassoSaml2Assertion * assertion,
				 const char *url, unsigned long tolerance_us)
{
	apr_time_t now;
	LassoSaml2SubjectConfirmation *sc;
	LassoSaml2SubjectConfirmationData *scd;

	if (assertion->Subject == NULL) {
		return 0;
	} else if (!LASSO_IS_SAML2_SUBJECT(assertion->Subject)) {
		fprintf(stderr, "SAML: Wrong type of Subject node.\n");
		return -1;
	}

	if (assertion->Subject->SubjectConfirmation == NULL) {
		return 0;
	} else if (!LASSO_IS_SAML2_SUBJECT_CONFIRMATION
		(assertion->Subject->SubjectConfirmation)) {
		fprintf(stderr, "SAML: Wrong type of SubjectConfirmation node.\n");
		return -1;
	}

	sc = assertion->Subject->SubjectConfirmation;
	if (sc->Method == NULL ||
	    strcmp(sc->Method, SAML_BEARER_CONFIRMATION_METHOD) != 0) {
		fprintf(stderr, "SAML: Invalid Method in SubjectConfirmation.\n");
		return -1;
	}

	scd = sc->SubjectConfirmationData;
	if (scd == NULL) {
		fprintf(stderr,
			"SAML: SubjectConfirmationData is required for bearer confirmation.\n");
		return -1;
	} else if (!LASSO_IS_SAML2_SUBJECT_CONFIRMATION_DATA(scd)) {
		fprintf(stderr,
			"SAML: Wrong type of SubjectConfirmationData node.\n");
		return -1;
	}

	now = apr_time_now();

	if (saml_validate_time_bound(scd->NotBefore, now, tolerance_us, 1,
				     "SAML: Invalid timestamp in NotBefore in SubjectConfirmationData.\n",
				     "SAML: NotBefore in SubjectConfirmationData was in the future.\n") != 0)
		return -1;

	if (saml_validate_time_bound(scd->NotOnOrAfter, now, tolerance_us, 0,
				     "SAML: Invalid timestamp in NotOnOrAfter in SubjectConfirmationData.\n",
				     "SAML: NotOnOrAfter in SubjectConfirmationData was in the past.\n") != 0)
		return -1;

	if (scd->Recipient) {
		if (strcmp(scd->Recipient, url) != 0) {
			fprintf(stderr,
				"SAML: Wrong Recipient in SubjectConfirmationData. "
				"Current URL is: %s, Recipient is %s\n",
				url, scd->Recipient);
			return -1;
		}
	}

	return 0;
}

/* Validate Assertion Conditions NotBefore/NotOnOrAfter time constraints */
static int saml_validate_conditions(LassoSaml2Assertion *assertion,
					  unsigned long tolerance_us)
{
	apr_time_t now;

	if (assertion->Conditions == NULL)
		return 0;

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
static int saml_validate_audience(LassoSaml2Assertion *assertion,
				  const char *sp_entity_id)
{
	GList *ar_list;
	LassoSaml2AudienceRestriction *ar;
	int found = 0;

	if (assertion->Conditions == NULL || sp_entity_id == NULL)
		return 0;

	ar_list = assertion->Conditions->AudienceRestriction;
	for (; ar_list != NULL; ar_list = ar_list->next) {
		if (!LASSO_IS_SAML2_AUDIENCE_RESTRICTION(ar_list->data))
			continue;
		ar = LASSO_SAML2_AUDIENCE_RESTRICTION(ar_list->data);
		if (ar->Audience &&
		    strcmp(ar->Audience, sp_entity_id) == 0) {
			found = 1;
			break;
		}
	}

	if (!found) {
		fprintf(stderr,
			"SAML: SP Entity ID '%s' not found in AudienceRestriction.\n",
			sp_entity_id);
		return -1;
	}

	return 0;
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
	if (response->parent.Destination == NULL)
		return 0;

	if (strcmp(response->parent.Destination, acs_url) == 0)
		return 0;

	fprintf(stderr,
		"SAML: Invalid Destination on Response. Should be %s, but was %s\n",
		acs_url, response->parent.Destination);
	return -1;
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

	return assertion;
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

static void saml_auth_fail(struct saml_ctx_st *ctx)
{
	lasso_login_destroy(ctx->login);
	ctx->login = NULL;
}

static int saml_auth_pass(void *_ctx, const char *saml_response,
			  unsigned pass_len)
{
	struct saml_ctx_st *ctx = _ctx;
	int rc;
	LassoSamlp2Response *response;
	LassoSaml2Assertion *assertion;
	unsigned long tolerance_us;

	rc = lasso_login_process_authn_response_msg(ctx->login,
						    (gchar *) saml_response);
	if (rc != 0) {
		fprintf(stderr, "SAML: Error processing authn response\n");
		fprintf(stderr, "SAML: Lasso error: [%i] %s\n", rc,
			lasso_strerror(rc));
		goto auth_fail;
	}

	if (saml_store_name_id(ctx) != 0)
		goto auth_fail;

	response = LASSO_SAMLP2_RESPONSE(LASSO_PROFILE(ctx->login)->response);

	if (saml_validate_response_destination(response,
					       ctx->vctx->config->acs_url) != 0)
		goto auth_fail;

	assertion = saml_get_single_assertion(response);
	if (assertion == NULL)
		goto auth_fail;

	if (saml_reject_sha1_signature(assertion) != 0)
		goto auth_fail;

	tolerance_us = ctx->vctx->config->clock_skew_tolerance * 1000000;

	rc = saml_validate_conditions(assertion, tolerance_us);
	if (rc != 0) {
		goto auth_fail;
	}

	rc = saml_validate_audience(assertion, ctx->vctx->config->sp_entity_id);
	if (rc != 0) {
		goto auth_fail;
	}

	rc = saml_validate_subject(assertion, ctx->vctx->config->acs_url, tolerance_us);
	if (rc != 0) {
		goto auth_fail;
	}

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

/* Clean up vhost context: release Lasso server and runtime strings */
static void saml_vhost_deinit(void *_vctx)
{
	struct saml_vhost_ctx *vctx = _vctx;

	if (vctx) {
		if (vctx->server)
			g_object_unref(vctx->server);
		if (vctx->config) {
			if (vctx->config->idpname)
				g_free(vctx->config->idpname);
			if (vctx->config->sp_entity_id)
				g_free(vctx->config->sp_entity_id);
			if (vctx->config->idp_sso_dest_url)
				g_free(vctx->config->idp_sso_dest_url);
			if (vctx->config->acs_url)
				g_free(vctx->config->acs_url);
		}
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
	.group_list = NULL
};

#endif /* HAVE_SAML */
