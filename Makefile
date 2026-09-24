# Scivane —— 常用命令入口。所有路径都相对本文件所在目录解析。
# 装 App 只需要一条：make app（编译、打包、放到桌面）。

SHELL        := /bin/bash
ROOT         := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
API          := http://127.0.0.1:8710
# 运行期产物在用户目录下，不在仓库里 —— 与 config.py 的默认值一致
VAR_DIR      ?= $(HOME)/.scivane/var
LLAMA        := http://127.0.0.1:8111


.DEFAULT_GOAL := help

.PHONY: help
help:  ## 显示本表
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: app
app:  ## 编译 + 打包 + 安装到桌面
	@bash $(ROOT)/scripts/build_app.sh

.PHONY: health
health:  ## 查两层是否活着
	@echo "llama :8111"; curl -sf $(LLAMA)/health && echo || echo "  ✗ 未响应"
	@echo "api   :8710"; curl -sf $(API)/health && echo || echo "  ✗ 未响应"

.PHONY: logs
logs:  ## 跟踪后端日志
	@tail -f $(VAR_DIR)/logs/api.log $(VAR_DIR)/logs/llama-server.log

.PHONY: kill
kill:  ## 强收后端残留进程
	@pkill -f llama-server 2>/dev/null && echo "已收 llama-server" || echo "没有残留"
	@rm -f $(VAR_DIR)/run/backend.pids

.PHONY: clean
clean:  ## 清掉仓库里的编译中间产物（不动用户目录，也不动已装好的 App）
	@rm -rf $(ROOT)/app/macos/.build $(ROOT)/var/build
	@echo "已清理（var/app/Scivane.app 保留，桌面那份实体拷贝不受影响）"
	@echo "下次打包会重新下载自带的解释器（约 25MB，按 sha256 校验）"

# 运行期产物现在在用户目录下，所以**单独一条、且要确认**。
# 让 `make clean` 顺手删 ~/.scivane 下的东西是危险的：同一个目录下就是项目数据。
.PHONY: clean-runtime
clean-runtime:  ## 清掉运行期产物（日志 / 抠图 / 沙箱策略，在用户目录下）
	@echo "将删除：$(VAR_DIR)/{logs,run,jobs}"
	@echo "（项目数据在 ~/.scivane/projects，不受影响）"
	@read -p "确认？[y/N] " ok && [ "$$ok" = "y" ] || { echo "已取消"; exit 1; }
	@rm -rf $(VAR_DIR)/logs $(VAR_DIR)/run $(VAR_DIR)/jobs
	@echo "已清理 $(VAR_DIR)"

.PHONY: distclean
distclean: clean  ## 连成品 App 一起删
	@rm -rf $(ROOT)/var/app
	@echo "已删除 var/app —— 跑 make app 重建"

# 本机的附加命令：同目录下有 dev.mk（本地文件，不纳入版本控制）就一并引入，没有也不影响上面任何一条
-include $(ROOT)/dev.mk
