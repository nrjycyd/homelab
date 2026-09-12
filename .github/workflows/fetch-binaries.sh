#!/bin/bash
# ============================================================
# 二进制更新脚本（manifest + 双 Releases 方案）
#   - 查询上游 latest release
#   - 版本未变且 release 完好则跳过（差分 + 自愈）
#   - 下载 -> 大小校验 -> sha256 -> 可选签名校验
#   - asset 命名：{name}-{上游原名}（大小写不敏感去重程序名前缀）
#   - 上传到本仓库双 release：pkgs(最新) / backup(次新备份)
#   - 清理：按最长前缀归属，整组替换
#   - 仅将 manifest.json 写回仓库（二进制不入库）
# ============================================================
set -uo pipefail

CONFIG_FILE=".github/workflows/binaries.conf"
MANIFEST="manifest.json"
RELEASE_TAG="pkgs"          # 最新二进制
BACKUP_TAG="backup"         # 次新备份（回滚用）
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT

RELEASE_REPO="${GITHUB_REPOSITORY:-$(yq -r '.release_repo // ""' "$CONFIG_FILE" 2>/dev/null)}"
[[ -n "$RELEASE_REPO" ]] || { echo "❌ 未设置 release_repo 或 GITHUB_REPOSITORY"; exit 1; }

failures=()
declare -a pending_names=()
declare -a pending_entries=()
declare -A BACKUP_COPIED=()

echo "🟦 开始二进制更新 $(date '+%F %T')"

for cmd in gh curl jq yq unzip tar gzip; do
  command -v "$cmd" >/dev/null || { echo "❌ 缺少命令: $cmd"; exit 1; }
done

# --force 强制重建（忽略版本差分）；也可通过环境变量 FORCE_REBUILD=true 触发
FORCE_REBUILD=false
if [[ "${1:-}" == "--force" || "${FORCE_REBUILD:-}" == "true" ]]; then
  FORCE_REBUILD=true
  echo "🔧 强制重建模式：忽略版本差分"
fi

# ---------- 加载旧 manifest 版本（用于差分） ----------
declare -A old_tag
if [[ -f "$MANIFEST" ]]; then
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && old_tag["$k"]="$v"
  done < <(jq -r '.binaries | to_entries[] | [.key, .value.tag] | @tsv' "$MANIFEST" 2>/dev/null || true)
fi

if [[ ! -f "$MANIFEST" ]]; then
  jq -n '{schema:1, updated_at:"", status:"ok", binaries:{}}' > "$MANIFEST"
fi

count=$(yq '.binaries | length' "$CONFIG_FILE")
echo "📦 读取到 $count 个二进制任务"

# 加载 pkgs 现有 asset 名（差分自愈：release 被删/不齐时触发重建）
declare -A release_asset_set
while IFS= read -r a; do
  [[ -n "$a" ]] && release_asset_set["$a"]=1
done < <(gh release view "$RELEASE_TAG" --repo "$RELEASE_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)

# 收集全部 binary 名（用于最长前缀归属判定）
declare -a all_names=()
while IFS= read -r n; do
  [[ -n "$n" ]] && all_names+=("$n")
done < <(yq -r '.binaries[].name' "$CONFIG_FILE" 2>/dev/null || true)

# asset 命名规范：{name}-{上游原名}
# 原名开头若与 name 的某个前缀（不区分大小写，逐段缩短）匹配，且其后是分隔符/结尾，
# 则剥掉该前缀及一个分隔符，保留 rest；否则整个原名保留。
# 例：sing-box-releases + sing-box-1.14.0-... -> sing-box-releases-1.14.0-...
normalize_name() {
  local name="$1" original="$2"
  local lower_orig="${original,,}"
  local cand="$name" match="" after="" prev=""
  while [[ -n "$cand" ]]; do
    if [[ "$lower_orig" == "${cand,,}"* ]]; then
      match="$cand"
      break
    fi
    prev="$cand"
    cand="${cand%-*}"
    [[ "$cand" == "$prev" ]] && break
  done
  if [[ -n "$match" ]]; then
    after="${original:${#match}}"
    if [[ -z "$after" || "$after" == [-_.]* ]]; then
      after="${after#[-_.]}"
      echo "$name-$after"
      return
    fi
  fi
  echo "$name-$original"
}

# 最长 {name}- 前缀归属：返回 asset 归属的 binary 名（sing-box vs sing-box-releases 靠最长前缀区分）
asset_owner() {
  local asset="$1" best="" n
  for n in "${all_names[@]}"; do
    if [[ "$asset" == "$n-"* ]]; then
      if [[ -z "$best" || ${#n} -gt ${#best} ]]; then best="$n"; fi
    fi
  done
  echo "$best"
}

# ---------- 工具函数 ----------
# 在 release_json 中按 match 模式挑选 asset（* 通配、! 排除、| 分隔）
select_asset() {
  local release_json="$1" match="$2" type="$3"
  local pats=() excls=() seg
  IFS='|' read -ra segs <<< "$match"
  for seg in "${segs[@]}"; do
    if [[ "$seg" == !* ]]; then excls+=("${seg#!}"); else pats+=("$seg"); fi
  done
  local suffix="" asset_name hit p e result=""
  [[ -n "$type" && "$type" != "none" ]] && suffix=".$type"
  for asset_name in $(echo "$release_json" | jq -r '.assets[].name'); do
    hit=false
    for p in "${pats[@]}"; do
      if [[ "$asset_name" == $p ]]; then hit=true; break; fi
    done
    [[ "$hit" == true ]] || continue
    for e in "${excls[@]}"; do
      [[ "$asset_name" == $e ]] && { hit=false; break; }
    done
    [[ "$hit" == true ]] || continue
    # type=none（或空）表示无扩展名资产，suffix 为空，此处校验恒真
    [[ "$asset_name" == *"$suffix" ]] || continue
    result="$asset_name"
    break
  done
  echo "$result"
}

verify_asset() {
  local mode="$1" repo="$2" tag="$3" asset_name="$4" pkgfile="$5" sha256="$6" asset_url="$7"
  case "$mode" in
    checksums)
      local csums
      csums=$(curl -fsL --retry 2 --connect-timeout 10 \
        "https://github.com/$repo/releases/download/$tag/checksums.txt" 2>/dev/null) ||
      csums=$(curl -fsL --retry 2 --connect-timeout 10 \
        "https://github.com/$repo/releases/download/$tag/SHA256SUMS" 2>/dev/null) || return 1
      echo "$csums" | grep -F "$asset_name" | grep -q "$sha256" && return 0
      echo "$csums" | grep -F "$(basename "$asset_name")" | grep -q "$sha256" && return 0
      return 1 ;;
    minisig)
      local key="${MINISIGN_PUBKEY:-}"
      [[ -n "$key" ]] || { echo "    ⚠️ 缺少 MINISIGN_PUBKEY，跳过签名校验"; return 0; }
      curl -fsL --retry 2 --connect-timeout 10 -o "$pkgfile.minisig" "$asset_url.minisig" || return 1
      minisign -Vm "$pkgfile" -P "$key" || return 1 ;;
    *) return 0 ;;
  esac
}

# 确保指定 release 存在；nolatest 表示创建时不抢占 Latest
ensure_release() {
  local tag="$1" latest_flag="${2:-latest}"
  if ! gh release view "$tag" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    if [[ "$latest_flag" == "nolatest" ]]; then
      gh release create "$tag" --repo "$RELEASE_REPO" \
        --title "$tag" --notes "二进制镜像（manifest.json 为索引）" --latest=false || return 1
    else
      gh release create "$tag" --repo "$RELEASE_REPO" \
        --title "$tag" --notes "二进制镜像（manifest.json 为索引）" || return 1
    fi
  fi
}

# 上传 staging 内所有文件到单一 release（同名覆盖）
# 只取 $STAGE_ROOT 二级子目录（$STAGE_ROOT/<name>/<file>）内的真实 asset，排除 *.minisig 临时文件
upload_staged() {
  local -a staged=()
  while IFS= read -r f; do staged+=("$f"); done < <(find "$STAGE_ROOT" -mindepth 2 -type f ! -name '*.minisig' | sort)
  echo "    📋 待上传文件数: ${#staged[@]}"
  local f
  for f in "${staged[@]}"; do echo "      - $(basename "$f")"; done
  [[ ${#staged[@]} -gt 0 ]] || return 1
  gh release upload "$RELEASE_TAG" "${staged[@]}" --repo "$RELEASE_REPO" --clobber
}

# 打印某 release 的 asset 数量与列表（诊断用）
release_assets() {
  local tag="$1"
  gh release view "$tag" --repo "$RELEASE_REPO" --json assets \
    --jq '"      \(.assets | length) 个: " + ([.assets[].name] | join(", "))' 2>/dev/null || echo "      (无法读取 $tag assets)"
}

# 将 pkgs 中某程序的旧版本 asset 复制到 backup；复制的文件名集合写入全局 BACKUP_COPIED
copy_prev_to_backup() {
  local name="$1"
  local dir="$STAGE_ROOT/prev_$name"
  mkdir -p "$dir"
  gh release download "$RELEASE_TAG" --repo "$RELEASE_REPO" --pattern "$name-*" --dir "$dir" >/dev/null 2>&1 || true
  # 仅保留归属该 binary 的文件（过滤前缀重叠，如 sing-box vs sing-box-releases）
  local f base
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    [[ "$(asset_owner "$base")" == "$name" ]] || rm -f "$f"
  done
  local files
  files=$(find "$dir" -type f)
  if [[ -z "$files" ]]; then
    BACKUP_COPIED["$name"]=""
    rm -rf "$dir"
    return 0
  fi
  echo "    📦 复制旧版本到 $BACKUP_TAG"
  gh release upload "$BACKUP_TAG" $files --repo "$RELEASE_REPO" --clobber || \
    failures+=("$name: 备份 release 上传失败")
  local copied=""
  while IFS= read -r f; do
    [[ -n "$f" ]] && copied="$copied $(basename "$f")"
  done <<< "$files"
  BACKUP_COPIED["$name"]="$copied"
  rm -rf "$dir"
}

# 删除指定 release 中归属某 binary 且不在 keep_set 内的 asset（keep_set 为空则全部删除）
clean_release_binary() {
  local release_tag="$1" name="$2"
  shift 2
  local keep_set=("$@")
  local list asset k keep
  list=$(gh release view "$release_tag" --repo "$RELEASE_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)
  local -a del=()
  for asset in $list; do
    [[ "$(asset_owner "$asset")" == "$name" ]] || continue
    keep=false
    for k in "${keep_set[@]}"; do
      [[ "$k" == "$asset" ]] && { keep=true; break; }
    done
    [[ "$keep" == false ]] && del+=("$asset")
  done
  for asset in "${del[@]}"; do
    echo "    🗑️  删除 $release_tag 旧 asset: $asset"
    gh release delete-asset "$release_tag" "$asset" --repo "$RELEASE_REPO" --yes || true
  done
}

# ---------- 单个二进制处理 ----------
# 检查 pkgs 中某程序在 manifest 里声明的 asset 是否齐备（差分自愈判断）
release_assets_complete() {
  local name="$1"
  local expected
  expected=$(jq -r --arg n "$name" '.binaries[$n].assets[].file' "$MANIFEST" 2>/dev/null || true)
  [[ -n "$expected" ]] || return 1
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -n "${release_asset_set[$f]:-}" ]] || return 1
  done <<< "$expected"
  return 0
}

process_binary() {
  local i="$1"
  local name repo verify assets_count
  name=$(yq -r ".binaries[$i].name" "$CONFIG_FILE")
  repo=$(yq -r ".binaries[$i].repo" "$CONFIG_FILE")
  verify=$(yq -r ".binaries[$i].verify // \"none\"" "$CONFIG_FILE")
  assets_count=$(yq -r ".binaries[$i].assets | length" "$CONFIG_FILE")

  echo "🟩 $name ($repo) ..."

  # 获取上游 latest release（stderr 捕获进变量，不落盘）
  local release_json tag version api_err=""
  release_json=$(gh api "repos/$repo/releases/latest" --jq '.' 2>&1) || {
    api_err=$(echo "$release_json" | tail -n1)
    echo "    ❌ 获取 latest 失败: $api_err"
    failures+=("$name: 获取 latest release 失败")
    return 1
  }
  tag=$(echo "$release_json" | jq -r '.tag_name')
  version="${tag#v}"

  # 差分：版本未变且 release asset 齐备才跳过；release 被删/不齐或 --force 则重建
  if [[ "$FORCE_REBUILD" != true && "${old_tag[$name]:-}" == "$tag" ]]; then
    if release_assets_complete "$name"; then
      echo "    ⏭️  跳过 $name：$version 未变（release 完好）"
      return 0
    else
      echo "    🔧 $name：$version 未变但 release 缺失/不完整，触发重建"
    fi
  fi

  local stage_dir="$STAGE_ROOT/$name"
  mkdir -p "$stage_dir"
  local assets_json="[]" j asset_name asset_url asset_size

  for ((j=0; j<assets_count; j++)); do
    local match type
    match=$(yq -r ".binaries[$i].assets[$j].match" "$CONFIG_FILE")
    type=$(yq -r ".binaries[$i].assets[$j].type" "$CONFIG_FILE")

    asset_name=$(select_asset "$release_json" "$match" "$type")
    if [[ -z "$asset_name" ]]; then
      echo "    ⚠️  未找到匹配 asset: $match (.$type)"
      failures+=("$name: 未找到 asset ($match / .$type)")
      continue
    fi
    asset_url=$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[] | select(.name==$n) | .browser_download_url')
    asset_size=$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[] | select(.name==$n) | .size')

    # 下载防线：--fail + 重试 + 大小校验
    local pkgfile="$stage_dir/$asset_name"
    echo "    ⬇️  $asset_name ($version)"
    if ! curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 600 \
        -o "$pkgfile" "$asset_url"; then
      echo "    ❌ 下载失败"
      failures+=("$name: 下载失败")
      continue
    fi

    local down_size sha256
    down_size=$(stat -c%s "$pkgfile")
    if [[ "$down_size" != "$asset_size" ]]; then
      echo "    ❌ 大小校验失败: $down_size != $asset_size"
      failures+=("$name: 大小不符")
      rm -f "$pkgfile"
      continue
    fi
    sha256=$(sha256sum "$pkgfile" | awk '{print $1}')

    if ! verify_asset "$verify" "$repo" "$tag" "$asset_name" "$pkgfile" "$sha256" "$asset_url"; then
      echo "    ❌ 签名/checksum 校验失败"
      failures+=("$name: 签名/checksum 校验失败")
      rm -f "$pkgfile"
      continue
    fi

    # 统一命名 {name}-{上游原名}（大小写不敏感去重程序名前缀）
    local new_name
    new_name=$(normalize_name "$name" "$asset_name")
    mv -f "$pkgfile" "$stage_dir/$new_name"

    assets_json=$(jq --arg file "$new_name" --arg type "$type" --arg sha256 "$sha256" \
      --arg size "$asset_size" --arg source "$asset_url" \
      --arg mirror "https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG/$new_name" \
      '. + [{file:$file, type:$type, sha256:$sha256, size:$size, source:$source, mirror:$mirror}]' \
      <<<"$assets_json")
  done

  # 该 binary 至少一个 asset 通过校验才计入待发布
  if [[ -z "$(ls -A "$stage_dir" 2>/dev/null)" ]]; then
    echo "    ❌ $name 没有任何 asset 通过校验，不发布"
    return 1
  fi

  local entry prev_tag
  prev_tag="${old_tag[$name]:-}"
  entry=$(jq -n --arg tag "$tag" --arg version "$version" --arg repo "$repo" \
    --arg prev_tag "$prev_tag" --argjson assets "$assets_json" \
    '{version:$version, tag:$tag, prev_tag:$prev_tag, repo:$repo, assets:$assets}')
  pending_names+=("$name")
  pending_entries+=("$entry")
  echo "    ✅ $name 已暂存 $version（待统一上传）"
  return 0
}

# ---------- 主循环 ----------
for ((i=0; i<count; i++)); do
  process_binary "$i" || true
done

# ---------- 统一发布到双 release ----------
if [[ ${#pending_names[@]} -gt 0 ]]; then
  ok=true
  ensure_release "$BACKUP_TAG" nolatest || ok=false
  ensure_release "$RELEASE_TAG" || ok=false
  if [[ "$ok" == true ]]; then
    # 1) 每个待更新 binary：旧版复制到 backup，并记录复制集合
    for bn in "${pending_names[@]}"; do
      copy_prev_to_backup "$bn"
    done
    # 2) 清理 backup 中归属这些 binary 且不在复制集合里的资产（清除更旧残留）
    for bn in "${pending_names[@]}"; do
      clean_release_binary "$BACKUP_TAG" "$bn" ${BACKUP_COPIED["$bn"]}
    done
    # 3) 清理 pkgs 中归属这些 binary 的旧资产（整组替换）
    for bn in "${pending_names[@]}"; do
      clean_release_binary "$RELEASE_TAG" "$bn"
    done
    # 4) 上传新资产到 latest
    echo "📤 上传到 $RELEASE_TAG ..."
    echo "    👉 上传前 $RELEASE_TAG:"
    release_assets "$RELEASE_TAG"
    if upload_staged; then
      echo "✅ 上传完成"
      echo "    👉 上传后 $RELEASE_TAG:"
      release_assets "$RELEASE_TAG"
      echo "    👉 $BACKUP_TAG 状态:"
      release_assets "$BACKUP_TAG"

      # 上传后校验：pkgs 必须有 asset，否则视为失败（防"提示成功实则为空"）
      pkg_count=$(gh release view "$RELEASE_TAG" --repo "$RELEASE_REPO" --json assets --jq '.assets | length' 2>/dev/null || echo 0)
      if [[ "$pkg_count" == "0" ]]; then
        echo "❌ 上传后 $RELEASE_TAG 为空"
        failures+=("上传后 $RELEASE_TAG 无任何 asset")
      fi

      # 5) 合并 manifest
      local_now=$(date -u +%FT%TZ)
      tmp_manifest="$MANIFEST.tmp"
      cp "$MANIFEST" "$tmp_manifest"
      for ((k=0; k<${#pending_names[@]}; k++)); do
        jq --arg name "${pending_names[$k]}" --argjson entry "${pending_entries[$k]}" \
          --arg updated "$local_now" \
          '.binaries[$name] = $entry | .updated_at = $updated' "$tmp_manifest" > "$tmp_manifest.2"
        mv -f "$tmp_manifest.2" "$tmp_manifest"
      done
      mv -f "$tmp_manifest" "$MANIFEST"
    else
      echo "❌ 上传 $RELEASE_TAG 失败"
      failures+=("上传 Releases 失败")
    fi
  else
    failures+=("创建 release 失败")
  fi
fi

# ---------- 确保 pkgs 为 Latest（先取消 backup，再标记 pkgs） ----------
if gh release view "$BACKUP_TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release edit "$BACKUP_TAG" --repo "$RELEASE_REPO" --latest=false || true
  echo "ℹ️ $BACKUP_TAG 已取消 Latest 标记"
fi
if gh release view "$RELEASE_TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release edit "$RELEASE_TAG" --repo "$RELEASE_REPO" --latest || true
  echo "✅ $RELEASE_TAG 已标记为 Latest"
fi

# ---------- 清理过期条目（config 是唯一事实来源，每次运行都执行） ----------
# 1) manifest 删除已不在 config 的 binary 条目（如曾被移除的 xray）
valid=$(yq -r '.binaries[].name' "$CONFIG_FILE" 2>/dev/null | jq -R -s -c 'split("\n") | map(select(. != ""))')
jq --argjson valid "$valid" '.binaries |= with_entries(select(.key as $k | $valid | index($k)))' "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"

# 2) 删除两个 release 中不属于任何配置 binary 的孤儿资产（manifest.json 是工作流挂载的索引，保留）
for tag in "$RELEASE_TAG" "$BACKUP_TAG"; do
  while read -r a; do
    [[ -n "$a" && "$a" != "manifest.json" && -z "$(asset_owner "$a")" ]] && {
      echo "    🗑️  清理孤儿资产 $tag: $a"
      gh release delete-asset "$tag" "$a" --repo "$RELEASE_REPO" --yes || true
    }
  done < <(gh release view "$tag" --repo "$RELEASE_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)
done

# ---------- 汇总 ----------
if [[ ${#failures[@]} -gt 0 ]]; then
  jq --arg s "$(printf '%s\n' "${failures[@]}")" \
    '.status = "partial"' "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
  echo "⚠️  存在失败项："
  printf '  - %s\n' "${failures[@]}"
else
  echo "🎉 全部更新完成 $(date '+%F %T')"
fi
