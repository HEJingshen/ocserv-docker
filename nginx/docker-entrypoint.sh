#!/bin/sh
set -e

# ============================================
# Nginx Docker Entrypoint Script
# ============================================
# 使用环境变量生成 nginx 配置文件
# 从模板文件生成实际配置

TEMPLATE_DIR=/etc/nginx/templates
CONF_DIR=/etc/nginx/conf.d

# 检查模板目录是否存在
if [ -d "$TEMPLATE_DIR" ]; then
    echo "Generating nginx configuration from templates..."
    
    # 遍历所有模板文件
    for template in "$TEMPLATE_DIR"/*.conf.template; do
        if [ -f "$template" ]; then
            # 获取文件名（不含路径和.template后缀）
            filename=$(basename "$template" .template)
            
            echo "Processing: $template -> $CONF_DIR/$filename"
            
            # 使用 envsubst 替换环境变量
            envsubst '${DOMAIN}' < "$template" > "$CONF_DIR/$filename"
        fi
    done
    
    echo "Nginx configuration generated successfully."
else
    echo "No templates directory found, using existing configuration."
fi

# 启动 nginx
exec nginx -g 'daemon off;'