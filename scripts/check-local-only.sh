#!/bin/sh
# scripts/check-local-only.sh — “自有内容只留本地”的提交/推送闸门
#
# 用法：
#   ./scripts/check-local-only.sh                       检查暂存区（pre-commit）
#   ./scripts/check-local-only.sh --staged              同上
#   ./scripts/check-local-only.sh --all                 检查 HEAD 的已跟踪文件（推送前/审计）
#   ./scripts/check-local-only.sh --range <rev-range>   检查待推提交（pre-push 调用）
#   ./scripts/check-local-only.sh --install-hooks       启用仓库自带的 .githooks
#
# 退出码：0 通过；1 命中；2 用法或环境错误。
# 规则、本地专属路径与处置办法见仓库根目录的 AGENTS.md。
# 本机敏感字面量放在 .git/info/local-denylist（一行一个，# 开头为注释），不随仓库分发。

set -eu

top=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "!! 不在 git 仓库里，无法检查" >&2
	exit 2
}
cd "$top"

mode=staged
range=
case ${1:-} in
'' | --staged)
	mode=staged
	;;
--all)
	mode=all
	;;
--range)
	[ $# -ge 2 ] || {
		echo "!! --range 需要一个 git 版本范围" >&2
		exit 2
	}
	mode=range
	range=$2
	;;
--install-hooks)
	git config core.hooksPath .githooks
	echo "已启用 .githooks（core.hooksPath=.githooks）"
	exit 0
	;;
-h | --help)
	sed -n '2,14p' "$0"
	exit 0
	;;
*)
	echo "用法: $0 [--staged|--all|--range <rev-range>|--install-hooks]" >&2
	exit 2
	;;
esac

fail=0

note() {
	printf '%s\n' "$*" >&2
}

report() {
	[ -n "$1" ] || return 0
	note "!! $2"
	printf '%s\n' "$1" | while IFS= read -r line; do
		if [ -n "$line" ]; then
			note "   $line"
		fi
	done
	fail=1
}

# 本地专属路径：命中即拒绝。这里只列“绝不该出现在 GitHub 上”的路径。
check_path() {
	case $1 in
	docs/* | local/* | notes/* | secrets/* | 原厂备份/* | Airoha/* | \
		release/* | logs/* | bin/* | build_dir/* | staging_dir/* | tmp/* | \
		dl/* | feeds/* | files/* | clone-sda/* | \
		.config | .config.* | version | \
		private-key.pem | */private-key.pem | public-key.pem | */public-key.pem | \
		scripts/cf-set-aaaa.sh | \
		*.itb | *.tar.zst)
		note "!! 本地专属路径被加入版本控制: $1"
		fail=1
		;;
	esac
}

# 通用高置信特征：私钥、token、Authorization 头。真实密码靠 local-denylist 拦截。
generic='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|CF_TOKEN[[:space:]]*=|AWS_SECRET_ACCESS_KEY[[:space:]]*[=:]|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|Authorization: Bearer [A-Za-z0-9._-]{20,}'

paths=$(mktemp "${TMPDIR:-/tmp}/ponwrt-paths.XXXXXX")
changed=$(mktemp "${TMPDIR:-/tmp}/ponwrt-changed.XXXXXX")
patterns=$(mktemp "${TMPDIR:-/tmp}/ponwrt-local-denylist.XXXXXX")
trap 'rm -f "$paths" "$changed" "$patterns"' EXIT INT TERM

for f in .git/info/local-denylist local/local-denylist; do
	[ -f "$f" ] || continue
	sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$f" >>"$patterns"
done

has_patterns=0
if [ -s "$patterns" ]; then
	has_patterns=1
fi

# 检查一批“路径 + 内容获取命令”的组合。内容命令必须输出该文件内容。
# 用法：scan_paths <路径清单文件> <git show 目标前缀>
scan_paths() {
	list=$1
	prefix=$2
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		if [ "$has_patterns" -eq 1 ] &&
			git show "$prefix:$p" 2>/dev/null | grep -q -I -F -f "$patterns"; then
			note "!! $3 含本机敏感字面量: $p"
			fail=1
		fi
		if git show "$prefix:$p" 2>/dev/null | grep -q -I -E -e "$generic"; then
			note "!! $3 含疑似私钥/token: $p"
			fail=1
		fi
	done <"$list"
}

if [ "$mode" = range ]; then
	# shellcheck disable=SC2086
	commits=$(git rev-list $range 2>/dev/null) || {
		note "!! 无法解析版本范围: $range"
		exit 2
	}
	commit_count=$(printf '%s\n' "$commits" | grep -c . || true)
	path_range=$range
	content_range=$range
	if [ "$commit_count" -gt 200 ]; then
		tip=$(printf '%s\n' "$commits" | head -1)
		note "!! 待推提交超过 200 个，内容只扫描最新提交；路径仍检查全部提交"
		content_range=$tip
	fi
	# shellcheck disable=SC2086
	git log --format= --diff-filter=ACMR --name-only $path_range >"$paths" 2>/dev/null || true
	label="待推提交"
elif [ "$mode" = all ]; then
	git ls-files >"$paths"
	label="HEAD 全树"
else
	git diff --cached --name-only --diff-filter=ACMR >"$paths"
	label="暂存区"
fi

while IFS= read -r p; do
	if [ -n "$p" ]; then
		check_path "$p"
	fi
done <"$paths"

if [ "$mode" = range ]; then
	# 只看新增行（^+，排除 +++ 头），命中时打印 commit:file，不打印内容。
	# shellcheck disable=SC2086
	hits=$(git log -p --no-color --format='commit %H' $content_range 2>/dev/null |
			awk -v pf="$patterns" -v re="$generic" '
			BEGIN {
				n = 0
				if (pf != "") {
					while ((getline line < pf) > 0) {
						if (line != "") lits[++n] = line
					}
					close(pf)
				}
			}
			/^commit / { commit = $2; file = ""; next }
			/^\+\+\+ / { file = $2; sub(/^b\//, "", file); next }
			/^\+/ {
				for (i = 1; i <= n; i++) {
					if (index($0, lits[i]) > 0) { print commit ":" file; next }
				}
				if ($0 ~ re) print commit ":" file
			}
		' | sort -u || true)
	report "$hits" "$label 的新增内容命中本地专属特征（只列 commit:file，不打印内容）："
elif [ "$mode" = all ]; then
	if [ "$has_patterns" -eq 1 ]; then
		report "$(git grep -l -I -F -f "$patterns" HEAD -- . 2>/dev/null || true)" \
			"$label 含本机敏感字面量（只列位置，不打印内容）："
	fi

	# 通用密钥/token 特征只扫“本 fork 相对上游改过的文件”，避免把上游公开的
	# 测试密钥当成泄露；若找不到上游基线，则退回全树扫描并排除已知上游密钥目录。
	base=$(git merge-base HEAD origin/master 2>/dev/null || true)
	if [ -n "$base" ]; then
		git diff --name-only --diff-filter=ACMR "$base"..HEAD >"$changed"
		report "$(while IFS= read -r p; do
			[ -n "$p" ] || continue
			if git show "HEAD:$p" 2>/dev/null | grep -q -I -E -e "$generic"; then
				printf '%s\n' "$p"
			fi
		done <"$changed")" \
			"$label 的 fork 改动含疑似私钥/token（只列位置，不打印内容）："
	else
		report "$(git grep -l -I -E -e "$generic" HEAD -- . \
			':(exclude)package/boot/arm-trusted-firmware-microchipsw/src/keys/*' \
			2>/dev/null || true)" \
			"$label 含疑似私钥/token（只列位置，不打印内容）："
	fi
else
	scan_paths "$paths" '' "$label"
fi

if [ "$fail" -ne 0 ]; then
	note ""
	note "!! 已阻止 $label 进入仓库：以上内容属于“自有/本机”范围，只应留在本地。"
	note "!! 处置："
	note "!!   git restore --staged <路径>      取消暂存"
	note "!!   或把文件移到 docs/、local/ 等本地专属目录"
	note "!!   确实需要公开的，先脱敏；不要用 --no-verify 绕过。"
	note "!! 规则见 AGENTS.md。"
	exit 1
fi

echo "check-local-only: OK ($label)"
exit 0
