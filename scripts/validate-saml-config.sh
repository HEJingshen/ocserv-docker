#!/bin/sh
# SAML Configuration Validation Script
# Validates SAML INI configuration file and metadata file paths
#
# Usage: validate-saml-config.sh [config_file_path]
# Default config path: /etc/ocserv/saml/config.ini

set -eu

SCRIPT_NAME="validate-saml-config"
SAML_CONFIG="${1:-/etc/ocserv/saml/config.ini}"

log_info() {
    printf '[%s] INFO: %s\n' "${SCRIPT_NAME}" "$1"
}

log_error() {
    printf '[%s] ERROR: %s\n' "${SCRIPT_NAME}" "$1" >&2
}

log_ok() {
    printf '[%s] OK: %s\n' "${SCRIPT_NAME}" "$1"
}

# Check if config file exists
check_config_file() {
    if [ ! -f "${SAML_CONFIG}" ]; then
        log_error "Config file not found: ${SAML_CONFIG}"
        return 1
    fi
    log_ok "Config file exists: ${SAML_CONFIG}"
    return 0
}

# Extract and validate a field from INI config
check_field() {
    field="$1"
    required="${2:-true}"

    value=$(grep "^${field}=" "${SAML_CONFIG}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \t' || true)

    if [ -z "${value}" ]; then
        if [ "${required}" = "true" ]; then
            log_error "Missing required field: ${field}"
            return 1
        else
            log_info "Optional field not set: ${field}"
            return 0
        fi
    fi

    if [ ! -f "${value}" ]; then
        log_error "File not found for ${field}: ${value}"
        return 1
    fi

    # Check file is readable
    if [ ! -r "${value}" ]; then
        log_error "File not readable for ${field}: ${value}"
        return 1
    fi

    log_ok "${field} = ${value}"
    return 0
}

# Validate XML metadata file has basic SAML structure
check_metadata_format() {
    file="$1"
    type="$2"  # "sp" or "idp"

    if [ ! -f "${file}" ]; then
        return 1
    fi

    # Check for basic SAML metadata elements
    if ! grep -q '<EntityDescriptor' "${file}" 2>/dev/null; then
        log_error "Invalid ${type} metadata: missing EntityDescriptor element in ${file}"
        return 1
    fi

    log_ok "${type} metadata XML structure valid"
    return 0
}

# Validate PEM certificate/key files
check_pem_file() {
    file="$1"
    type="$2"  # "key" or "cert"

    if [ ! -f "${file}" ]; then
        return 1
    fi

    # Check for PEM format
    if ! grep -q 'BEGIN' "${file}" 2>/dev/null; then
        log_error "Invalid ${type} file: not in PEM format: ${file}"
        return 1
    fi

    log_ok "${type} file PEM format valid: ${file}"
    return 0
}

# Main validation
main() {
    errors=0

    log_info "Validating SAML configuration: ${SAML_CONFIG}"

    # Check config file exists
    if ! check_config_file; then
        exit 1
    fi

    # Required fields
    sp_meta=$(grep "^sp-metadata-file=" "${SAML_CONFIG}" 2>/dev/null | cut -d= -f2- | tr -d ' \t' || true)
    sp_key=$(grep "^sp-keyfile=" "${SAML_CONFIG}" 2>/dev/null | cut -d= -f2- | tr -d ' \t' || true)
    sp_cert=$(grep "^sp-cert=" "${SAML_CONFIG}" 2>/dev/null | cut -d= -f2- | tr -d ' \t' || true)
    idp_meta=$(grep "^idp-metadata-file=" "${SAML_CONFIG}" 2>/dev/null | cut -d= -f2- | tr -d ' \t' || true)

    # Check required fields and files
    if ! check_field "sp-metadata-file" "true"; then
        errors=$((errors + 1))
    elif [ -n "${sp_meta}" ]; then
        check_metadata_format "${sp_meta}" "sp" || errors=$((errors + 1))
    fi

    if ! check_field "sp-keyfile" "true"; then
        errors=$((errors + 1))
    elif [ -n "${sp_key}" ]; then
        check_pem_file "${sp_key}" "key" || errors=$((errors + 1))
    fi

    if ! check_field "sp-cert" "true"; then
        errors=$((errors + 1))
    elif [ -n "${sp_cert}" ]; then
        check_pem_file "${sp_cert}" "cert" || errors=$((errors + 1))
    fi

    if ! check_field "idp-metadata-file" "true"; then
        errors=$((errors + 1))
    elif [ -n "${idp_meta}" ]; then
        check_metadata_format "${idp_meta}" "idp" || errors=$((errors + 1))
    fi

    # Optional field
    check_field "idp-cert" "false" || errors=$((errors + 1))

    # Summary
    if [ "${errors}" -gt 0 ]; then
        log_error "Validation failed with ${errors} errors"
        exit 1
    fi

    log_info "SAML configuration validation passed"
    exit 0
}

main "$@"