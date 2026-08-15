# golang环境配置 for visual studio code

## 1. 安装go的开发包

## 2.安装vscode

### 1.打开VS Code 安装golang扩展

- 点击左侧扩展图标（或按Ctrl+Shift+X）
- 搜索"Go":安装由"Go Team at Google"发布的Go扩展
- 安装golang工具
  - 安装代码格式化工具:go install golang.org/x/tools/cmd/goimports@latest
  - 代码安全检查：go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
  - 安装 gocode：go install github.com/mdempsky/gocode@latest --- 代码补全
  - 安装 gopkgs：go install github.com/uudashr/gopkgs/v2/cmd/gopkgs@latest --- 包管理
  - 安装 go-outline：go install github.com/ramya-rao-a/go-outline@latest --- 代码大纲
  - 安装 go-symbols：go install github.com/acroca/go-symbols@latest --- 符号搜搜
  - 安装 guru：go install golang.org/x/tools/cmd/guru@latest  --- 代码分析
  - 安装 gorename：go install golang.org/x/tools/cmd/gorename@latest --- 重命名
  - 安装 gotests：go install github.com/cweill/gotests/gotests@latest --- 测试生成
  - 安装 gomodifytags：go install github.com/fatih/gomodifytags@latest --- 结构体标签修改
  - 安装 impl：go install github.com/josharian/impl@latest --- 接口实现
  - 安装 dlv：go install github.com/go-delve/delve/cmd/dlv@latest --- 调试器
  - 安装 goplay：go install github.com/haya14busa/goplay/cmd/goplay@latest --- Go playgound 本地运行go代码片段
  - 安装 gotest：go install github.com/cweill/gotests/gotest@latest --- 测试运行
  - 安装 godef：go install github.com/rogpeppe/godef@latest --- 代码跳转
  - 安装 goreturns：go install github.com/sqs/goreturns@latest ---代码补全
  - 安装 golint：go install golang.org/x/lint/golint@latest --- 代码检查


### 安装脚本
下面是将文档中安装命令改写为 shell 脚本的内容，可保存为 `install_go_tools.sh` 并运行：

```bash
#!/usr/bin/env bash
set -euo pipefail

# Install Go tools for VS Code (one go install per line).
# Requirements: Go installed and at least Go 1.16 for `go install pkg@version` behavior.
# Ensure $GOBIN (or $GOPATH/bin) is in your PATH after running this script.

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is not installed or not in PATH"
  exit 1
fi

# Determine GOBIN (fall back to GOPATH/bin if empty) and ensure it exists.
GOBIN="$(go env GOBIN)"
if [ -z "$GOBIN" ] || [ "$GOBIN" = "<nil>" ]; then
  GOBIN="$(go env GOPATH)/bin"
fi
mkdir -p "$GOBIN"
echo "Installing tools to: $GOBIN"

# Install each tool (one command per tool).
go install golang.org/x/tools/cmd/goimports@latest
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
go install github.com/mdempsky/gocode@latest
go install github.com/uudashr/gopkgs/v2/cmd/gopkgs@latest
go install github.com/ramya-rao-a/go-outline@latest
go install github.com/acroca/go-symbols@latest
go install golang.org/x/tools/cmd/guru@latest
go install golang.org/x/tools/cmd/gorename@latest
go install github.com/cweill/gotests/gotests@latest
go install github.com/fatih/gomodifytags@latest
go install github.com/josharian/impl@latest
go install github.com/go-delve/delve/cmd/dlv@latest
go install github.com/haya14busa/goplay/cmd/goplay@latest
go install github.com/cweill/gotests/gotest@latest
go install github.com/rogpeppe/godef@latest
go install github.com/sqs/goreturns@latest
go install golang.org/x/lint/golint@latest

echo "All tools installed."
echo "If the installed binaries are not available in your shell, add this to your shell profile:"
echo "  export PATH=\"$PATH:$GOBIN\""
```
