# GitHub Actions SHA 维护说明

本仓库将 GitHub Actions 固定到完整 commit SHA。每个固定的 action 引用旁边都应保留同一行版本提示，方便 Dependabot 和人工审核者确认该 SHA 对应的 release 版本。

## Dependabot 更新

Dependabot 会在每月 1 日 09:00 Asia/Shanghai 检查 GitHub Actions 更新，并把 action 更新合并到一个 pull request 中。

合并 Dependabot pull request 前需要完成以下审核：

- patch 和 minor 更新可以在 CI 通过，并且 release notes 未显示破坏性 workflow 变更时接受。
- major 更新必须人工审核后再合并。重点检查 Node runtime 变化、最低 runner 版本要求、被移除的 inputs、被移除的 outputs，以及默认行为变化。
- `aquasecurity/trivy-action` 更新需要额外谨慎。检查 release notes、安全公告，以及 release 是否签名或不可变。

## 验证

合并维护更新前运行以下检查：

```bash
actionlint .github/workflows/*.yml
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/workflows/*.yml
git diff --check
rg -n '@(master|main|latest|v[0-9]+)(\s|$)' .github/workflows
```

最后一条命令不应返回任何匹配结果。

对于 pull request，还需要确认两个镜像构建 workflow 都通过，Docker metadata 输出的 tag 没有意外变化，build 和 push 参数保持不变，并且 Trivy 继续保持 `exit-code: '0'`，除非发布策略被有意调整。
