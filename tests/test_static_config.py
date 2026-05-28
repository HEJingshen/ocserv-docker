#!/usr/bin/env python3
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]


class StaticConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dockerfile = (ROOT_DIR / "Dockerfile").read_text(encoding="utf-8")
        cls.exporter_dockerfile = (ROOT_DIR / "exporter" / "Dockerfile").read_text(encoding="utf-8")
        cls.ocserv_template = (ROOT_DIR / "config" / "ocserv.conf.template").read_text(encoding="utf-8")
        cls.env_example = (ROOT_DIR / ".env.example").read_text(encoding="utf-8")
        cls.dockerignore = (ROOT_DIR / ".dockerignore").read_text(encoding="utf-8")
        cls.workflow = (ROOT_DIR / ".github" / "workflows" / "docker-build.yml").read_text(encoding="utf-8")
        cls.compose = (ROOT_DIR / "docker-compose.yml").read_text(encoding="utf-8")
        cls.monitoring_compose = (ROOT_DIR / "docker-compose.monitoring.yml").read_text(encoding="utf-8")
        cls.docs_readme = (ROOT_DIR / "docs" / "README.md").read_text(encoding="utf-8")
        cls.docs_memory_issue = (ROOT_DIR / "docs" / "ocserv-docker-memory-issue.md").read_text(encoding="utf-8")
        cls.cert_auth_script = (ROOT_DIR / "scripts" / "ocserv-cert-auth.sh").read_text(encoding="utf-8")
        cls.render_script = (ROOT_DIR / "scripts" / "render-ocserv-conf.sh").read_text(encoding="utf-8")
        cls.fail2ban_setup = (ROOT_DIR / "scripts" / "setup-fail2ban.sh").read_text(encoding="utf-8")
        cls.fail2ban_jail = (ROOT_DIR / "fail2ban" / "jail.d" / "nginx-auth.conf").read_text(encoding="utf-8")

    def test_ocserv_seccomp_build_support_is_disabled(self):
        self.assertNotIn("libseccomp-dev", self.dockerfile)
        self.assertNotIn("-Dseccomp=enabled", self.dockerfile)
        self.assertEqual(2, self.dockerfile.count("-Dseccomp=disabled"))

    def test_worker_isolation_defaults_to_disabled(self):
        enabled_pattern = re.compile(r"^[ \t]*isolate-workers[ \t]*=[ \t]*true[ \t]*$", re.MULTILINE)
        disabled_pattern = re.compile(r"^[ \t]*isolate-workers[ \t]*=[ \t]*false[ \t]*$", re.MULTILINE)

        self.assertIsNone(enabled_pattern.search(self.ocserv_template))
        self.assertIsNotNone(disabled_pattern.search(self.ocserv_template))

    def test_self_managed_alpine_rootfs_is_not_used(self):
        combined = "\n".join([self.dockerfile, self.exporter_dockerfile])

        self.assertIn("ARG ALPINE_IMAGE=alpine:3.23.4", self.dockerfile)
        self.assertIn("ARG ALPINE_IMAGE=alpine:3.23.4", self.exporter_dockerfile)
        for old_token in (
            "alpine-" + "rootfs",
            "ALPINE_" + "MINIROOTFS_SHA256",
            "ALPINE_" + "ARCH",
            "ALPINE_" + "PATCH_VERSION",
            "alpine-" + "mini" + "rootfs",
        ):
            self.assertNotIn(old_token, combined)

    def test_monitoring_uses_same_letsencrypt_certificate_mounts(self):
        old_cert_dir_var = "SSL_" + "CERT_DIR"
        self.assertNotIn(old_cert_dir_var, self.env_example)
        self.assertNotIn(old_cert_dir_var, self.monitoring_compose)

        cert_mount = "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem:/etc/ocserv/fullchain.pem:ro"
        key_mount = "/etc/letsencrypt/live/${DOMAIN}/privkey.pem:/etc/ocserv/privkey.pem:ro"
        nginx_cert_mount = (
            "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem:"
            "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem:ro"
        )
        nginx_key_mount = (
            "/etc/letsencrypt/live/${DOMAIN}/privkey.pem:"
            "/etc/letsencrypt/live/${DOMAIN}/privkey.pem:ro"
        )

        self.assertIn(cert_mount, self.compose)
        self.assertIn(key_mount, self.compose)
        self.assertIn(nginx_cert_mount, self.monitoring_compose)
        self.assertIn(nginx_key_mount, self.monitoring_compose)

    def test_ocserv_auth_tool_has_isolated_persistent_mounts(self):
        self.assertIn("ocserv-auth:", self.compose)
        self.assertIn("- tools", self.compose)
        self.assertIn("network_mode: none", self.compose)
        ocserv_service = self.compose.split("\n  ocserv-auth:", 1)[0]
        auth_service = self.compose.split("\n  ocserv-auth:", 1)[1]
        self.assertNotIn("ALLOW_EMPTY_P12_PASSWORD", ocserv_service)
        self.assertIn("ALLOW_EMPTY_P12_PASSWORD=${ALLOW_EMPTY_P12_PASSWORD:-true}", auth_service)

        self.assertIn("./config/client-ca/public:/etc/ocserv/ca:ro", self.compose)
        self.assertIn("./config/config-per-user:/etc/ocserv/config-per-user:ro", self.compose)
        self.assertNotIn("./config/client-ca/private:/var/lib/ocserv-auth/private-ca:ro", self.compose)

        private_mount = "./config/client-ca/private:/var/lib/ocserv-auth/private-ca:rw"
        self.assertIn(private_mount, self.compose)
        self.assertNotIn("./config/client-ca/private:", ocserv_service)

    def test_optional_client_certificate_auth_is_env_controlled(self):
        self.assertIn('auth = "plain[passwd=/etc/ocserv/auth/ocpasswd]"', self.ocserv_template)
        self.assertIn("OCSERV_ENABLE_CERT_AUTH=false", self.env_example)
        self.assertIsNone(re.search(r'^[ \t]*enable-auth[ \t]*=[ \t]*"certificate"', self.ocserv_template, re.MULTILINE))
        self.assertIsNone(re.search(r"^[ \t]*ca-cert[ \t]*=[ \t]*/etc/ocserv/ca/ca-cert.pem", self.ocserv_template, re.MULTILINE))
        self.assertIsNone(re.search(r"^[ \t]*crl[ \t]*=[ \t]*/etc/ocserv/ca/crl.pem", self.ocserv_template, re.MULTILINE))
        self.assertIn("OCSERV_ENABLE_CERT_AUTH", self.render_script)
        self.assertIn('enable-auth = \\"certificate\\"', self.render_script)
        self.assertIn("ca-cert = /etc/ocserv/ca/ca-cert.pem", self.render_script)
        self.assertIn("crl = /etc/ocserv/ca/crl.pem", self.render_script)
        self.assertIn("config-per-user = /etc/ocserv/config-per-user/", self.ocserv_template)

    def test_compression_defaults_to_disabled_and_is_env_controlled(self):
        self.assertIn("OCSERV_ENABLE_COMPRESSION=false", self.env_example)
        self.assertIn("compression = false", self.ocserv_template)
        self.assertNotIn("compression = true", self.ocserv_template)
        self.assertIn("OCSERV_ENABLE_COMPRESSION", self.render_script)

    def test_occtl_socket_uses_dedicated_runtime_volume(self):
        exporter_service = self.monitoring_compose.split("\n  prometheus:", 1)[0]

        self.assertIn("occtl-socket-file = /run/ocserv/occtl.socket", self.ocserv_template)
        self.assertIn("ocserv-socket:/run/ocserv", self.compose)
        self.assertIn("ocserv-socket:/run/ocserv:ro", self.monitoring_compose)
        self.assertIn("OCSERV_SOCKET=/run/ocserv/occtl.socket", self.monitoring_compose)
        self.assertIn('OCSERV_SOCKET=/run/ocserv/occtl.socket', self.exporter_dockerfile)
        self.assertIn('user: "0:0"', exporter_service)
        self.assertIn("occtl socket queries require root peer credentials", exporter_service)
        self.assertIn("/run/ocserv/occtl.socket", self.docs_readme)
        self.assertIn("/run/ocserv/occtl.socket", self.docs_memory_issue)
        self.assertNotIn("ocserv-socket:/var/run", self.compose)
        self.assertNotIn("ocserv-socket:/var/run:ro", self.monitoring_compose)
        self.assertNotIn("/var/run/occtl.socket", self.docs_readme)
        self.assertNotIn("/var/run/occtl.socket", self.docs_memory_issue)

    def test_rendered_ocserv_config_uses_dedicated_runtime_volume(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output_file = Path(tmpdir) / "ocserv.conf"
            env = os.environ.copy()
            env.update(
                {
                    "DOMAIN": "vpn.example.com",
                    "ENV_FILE": str(ROOT_DIR / ".env.example"),
                    "OCSERV_CONF_OUTPUT": str(output_file),
                }
            )

            subprocess.run(
                [str(ROOT_DIR / "scripts" / "render-ocserv-conf.sh")],
                cwd=ROOT_DIR,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )

            rendered_config = output_file.read_text(encoding="utf-8")

        self.assertIn("occtl-socket-file = /run/ocserv/occtl.socket", rendered_config)
        self.assertNotIn("occtl-socket-file = /var/run/occtl.socket", rendered_config)

    def test_auth_docker_build_context_and_ci_are_validated(self):
        self.assertIn("!scripts/ocserv-cert-auth.sh", self.dockerignore)
        self.assertIn("docker build --pull -f auth/Dockerfile -t ocserv-auth:ci .", self.workflow)
        self.assertIn("OCSERV_TARBALL_SHA256", self.workflow)
        self.assertIn("sha256sum -c -", self.workflow)

    def test_image_defaults_are_pinned_in_env_example(self):
        self.assertIn("OCSERV_IMAGE=kingsonho/ocserv:1.4.2", self.env_example)
        self.assertIn("EXPORTER_IMAGE=kingsonho/ocserv-exporter:1.4.2", self.env_example)
        self.assertIn("GRAFANA_IMAGE=grafana/grafana:13.0.1-security-01", self.env_example)
        self.assertIn("NGINX_IMAGE=nginx:1.30.2-alpine3.23-slim", self.env_example)
        self.assertNotIn("OCSERV_IMAGE=kingsonho/ocserv:latest", self.env_example)
        self.assertNotIn("EXPORTER_IMAGE=kingsonho/ocserv-exporter:latest", self.env_example)

    def test_p12_empty_password_is_explicitly_configured(self):
        removed_file_password_var = "P12_EXPORT_PASSWORD" + "_FILE"
        self.assertIn("ALLOW_EMPTY_P12_PASSWORD=true", self.env_example)
        self.assertIn("ALLOW_EMPTY_P12_PASSWORD=${ALLOW_EMPTY_P12_PASSWORD:-true}", self.compose)
        self.assertIn("P12_EXPORT_PASSWORD=", self.env_example)
        self.assertIn("P12_EXPORT_PASSWORD=${P12_EXPORT_PASSWORD:-}", self.compose)
        self.assertNotIn(removed_file_password_var, self.env_example)
        self.assertNotIn(removed_file_password_var, self.compose)
        self.assertNotIn(removed_file_password_var, self.cert_auth_script)
        self.assertIn("validate_p12_export_policy()", self.cert_auth_script)
        self.assertIn("ALLOW_EMPTY_P12_PASSWORD must be true or false", self.cert_auth_script)
        self.assertIn("empty P12 export passwords are disabled", self.cert_auth_script)
        self.assertIn("set P12_EXPORT_PASSWORD or ALLOW_EMPTY_P12_PASSWORD=true", self.cert_auth_script)

    def test_fail2ban_uses_monitoring_port(self):
        self.assertIn("MONITORING_PORT", self.fail2ban_setup)
        self.assertIn('port     = ${MONITORING_PORT}', self.fail2ban_setup)
        self.assertIn('port="${MONITORING_PORT}"', self.fail2ban_setup)
        self.assertIn("port     = 8443", self.fail2ban_jail)
        self.assertNotIn("port     = http,https", self.fail2ban_setup)
        self.assertNotIn('port="http,https"', self.fail2ban_setup)

    def test_cert_auth_status_is_read_only_and_reissue_is_explicit(self):
        show_status_match = re.search(
            r"show_status\(\) \{(?P<body>.*?)\n\}",
            self.cert_auth_script,
            re.DOTALL,
        )
        self.assertIsNotNone(show_status_match)
        self.assertNotIn("ensure_ca", show_status_match.group("body"))
        self.assertNotIn("prepare_dirs", show_status_match.group("body"))

        manage_match = re.search(
            r"manage_certs\(\) \{(?P<body>.*?)\n\}",
            self.cert_auth_script,
            re.DOTALL,
        )
        self.assertIsNotNone(manage_match)
        manage_body = manage_match.group("body")
        self.assertIn("is_user_disabled", manage_body)
        self.assertIn("migrate_legacy_user_cert", manage_body)
        self.assertIn("artifact-missing", manage_body)

        self.assertIn("reissue_users()", self.cert_auth_script)
        self.assertIn("reissue)", self.cert_auth_script)
        self.assertIn("certtool_supports_required_options()", self.cert_auth_script)
        self.assertNotIn("certtool --version", self.cert_auth_script)
        self.assertIn('ISSUED_CERT_DIR="${CA_PRIVATE_DIR}/issued-certs"', self.cert_auth_script)
        self.assertIn('REVOKED_METADATA_DIR="${CA_PRIVATE_DIR}/revoked-metadata"', self.cert_auth_script)
        self.assertIn("current_user_cert_file()", self.cert_auth_script)
        self.assertIn("install_generated_user_cert()", self.cert_auth_script)
        self.assertIn("migrate_legacy_user_cert()", self.cert_auth_script)
        self.assertIn("user_p12_artifacts_present()", self.cert_auth_script)
        self.assertIn("artifact-missing", self.cert_auth_script)
        self.assertIn("confirm_revoke_users()", self.cert_auth_script)
        self.assertIn("revoke_from_cli()", self.cert_auth_script)
        self.assertIn("--yes|-y)", self.cert_auth_script)
        self.assertIn('revoke_users --skip-confirm "${users[@]}"', self.cert_auth_script)
        self.assertNotIn('cp -a "${CERT_DIR}/${user}/."', self.cert_auth_script)
        self.assertNotRegex(
            self.cert_auth_script,
            r"status\)\n\s+shift \|\| true\n\s+with_lock show_status",
        )

        generate_match = re.search(
            r"generate_user_cert_into_dir\(\) \{(?P<body>.*?)\n\}",
            self.cert_auth_script,
            re.DOTALL,
        )
        self.assertIsNotNone(generate_match)
        self.assertNotIn("die", generate_match.group("body"))

        show_status_body = show_status_match.group("body")
        self.assertNotIn("migrate_legacy_user_cert", show_status_body)
        self.assertNotIn("cleanup_user_pem_artifacts", show_status_body)

        install_match = re.search(
            r"install_generated_user_cert\(\) \{(?P<body>.*?)\n\}",
            self.cert_auth_script,
            re.DOTALL,
        )
        self.assertIsNotNone(install_match)
        install_body = install_match.group("body")
        self.assertIn('cp "${source_dir}/${username}.p12"', install_body)
        self.assertIn('cp "${source_dir}/${username}-cert.pem" "${issued_cert}"', install_body)
        self.assertIn('cleanup_user_pem_artifacts "${username}"', install_body)

        reissue_match = re.search(
            r"reissue_users\(\) \{(?P<body>.*?)\n\}",
            self.cert_auth_script,
            re.DOTALL,
        )
        self.assertIsNotNone(reissue_match)
        reissue_body = reissue_match.group("body")
        self.assertIn('[[ -f "${marker_file}" ]] || die', reissue_body)
        self.assertLess(
            reissue_body.index("generate_user_cert_into_dir"),
            reissue_body.index('rm -f "${marker_file}"'),
        )
        self.assertNotIn('\n        rm -f "${marker_file}"\n', reissue_body)
        self.assertIn('if ! rm -f "${marker_file}"; then', reissue_body)
        self.assertIn('rm -rf "${user_dir}" 2>/dev/null ||', reissue_body)
        self.assertIn('chmod -R u+rwX "${user_dir}"', reissue_body)
        self.assertIn('mv "${backup_dir}" "${user_dir}" 2>/dev/null || true', reissue_body)
        self.assertIn("disabled marker preserved and previous certificate state restored where possible", reissue_body)
        self.assertNotIn('rm -rf "${backup_dir}" || warn', reissue_body)
        self.assertIn('chmod -R u+rwX "${backup_dir}"', reissue_body)
        self.assertIn("failed to remove old backup directory containing private key material", reissue_body)
        self.assertIn('issued_file=$(issued_cert_file "${user}")', reissue_body)
        self.assertIn('mv "${issued_backup}" "${issued_file}" 2>/dev/null || true', reissue_body)

        interactive_revoke_match = re.search(
            r"interactive_revoke\(\) \{(?P<body>.*?)\n\}",
            self.cert_auth_script,
            re.DOTALL,
        )
        self.assertIsNotNone(interactive_revoke_match)
        interactive_revoke_body = interactive_revoke_match.group("body")
        self.assertIn('revoke_users "${users[@]}"', interactive_revoke_body)
        self.assertNotIn("--skip-confirm", interactive_revoke_body)


if __name__ == "__main__":
    unittest.main()
