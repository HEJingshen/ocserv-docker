#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE=${ENV_FILE:-"${PROJECT_DIR}/.env"}

env_value() {
    [ -f "${ENV_FILE}" ] || return 0
    awk -v key="$1" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                value = line
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
                sub(/[[:space:]]+#.*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
                    value = substr(value, 2, length(value) - 2)
                }
            }
        }
        END { print value }
    ' "${ENV_FILE}"
}

MONITORING_PORT=${MONITORING_PORT:-$(env_value MONITORING_PORT)}
MONITORING_PORT=${MONITORING_PORT:-8443}

case "${MONITORING_PORT}" in
    ''|*[!0-9]*)
        echo "❌ MONITORING_PORT 必须是数字: ${MONITORING_PORT}" && exit 1
        ;;
esac

if [ "${MONITORING_PORT}" -lt 1 ] || [ "${MONITORING_PORT}" -gt 65535 ]; then
    echo "❌ MONITORING_PORT 超出范围: ${MONITORING_PORT}" && exit 1
fi

echo "📦 安装 Fail2Ban..."
if command -v apt &> /dev/null; then
    sudo apt update && sudo apt install -y fail2ban nftables
elif command -v dnf &> /dev/null; then
    sudo dnf install -y fail2ban nftables
else
    echo "❌ 不支持的包管理器" && exit 1
fi

echo "📝 部署配置文件..."
sudo tee /etc/fail2ban/filter.d/nginx-auth.conf > /dev/null << 'EOF'
[Definition]
failregex = ^<HOST> - \S+ \[.*\] "\w+ /grafana/(login|api/login).*" (401|403) .*$
ignoreregex = ^<HOST> - \S+ \[.*\] "\w+ /(health|metrics|favicon|static|public|robots\.txt|\.well-known).*" .*$
EOF

sudo tee /etc/fail2ban/jail.d/nginx-auth.conf > /dev/null << EOF
[nginx-auth]
enabled  = true
port     = ${MONITORING_PORT}
filter   = nginx-auth
logpath  = ${PROJECT_DIR}/nginx/logs/access.log
maxretry = 5
findtime = 600
bantime  = 3600
action   = nftables-multiport[name=nginx-auth, port="${MONITORING_PORT}", protocol=tcp]
EOF

echo "🔄 重启 Fail2Ban 服务..."
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

echo "✅ 部署完成！请运行以下命令验证："
echo "   sudo fail2ban-client status nginx-auth"
