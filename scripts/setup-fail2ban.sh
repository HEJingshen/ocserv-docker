#!/bin/bash
set -e

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

# Resolve the repository root even though this script lives in scripts/.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
sudo tee /etc/fail2ban/jail.d/nginx-auth.conf > /dev/null << EOF
[nginx-auth]
enabled  = true
port     = http,https
filter   = nginx-auth
logpath  = ${PROJECT_DIR}/nginx/logs/access.log
maxretry = 5
findtime = 600
bantime  = 3600
action   = nftables-multiport[name=nginx-auth, port="http,https", protocol=tcp]
EOF

echo "🔄 重启 Fail2Ban 服务..."
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban

echo "✅ 部署完成！请运行以下命令验证："
echo "   sudo fail2ban-client status nginx-auth"
