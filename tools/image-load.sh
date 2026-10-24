#!/bin/bash
set -euo pipefail

# 用法: ./load-images-to-kind.sh <cluster-name> <tar-file1> [tar-file2] ...

CLUSTER="${1:?用法: $0 <kind-cluster-name> <image-tar1> [image-tar2] ...}"
shift

if [[ $# -eq 0 ]]; then
  echo "错误: 至少需要传入一个镜像 tar 文件路径" >&2
  exit 1
fi

# 获取 kind 节点列表（docker 容器名）
NODES="$(sudo kind get nodes --name "$CLUSTER")"

if [[ -z "$NODES" ]]; then
  echo "错误: 集群 '$CLUSTER' 没有找到节点" >&2
  exit 1
fi

echo "=== 集群: $CLUSTER ==="
echo "节点列表:"
echo "$NODES" | sed 's/^/  /'
echo

# 遍历每个 tar 文件
for tar_path in "$@"; do
  if [[ ! -f "$tar_path" ]]; then
    echo "!! 文件不存在，跳过: $tar_path" >&2
    continue
  fi

  echo ">>> 加载镜像: $tar_path"
  echo "    大小: $(du -sh "$tar_path" | cut -f1)"

  # 遍历每个节点
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue

    echo "  >> 导入到节点: $node"

    if docker exec -i "$node" ctr -n k8s.io images import \
        --all-platforms \
        --digests \
        - < "$tar_path" >/dev/null; then
      echo "  ✅ $node 完成"
    else
      echo "  ❌ $node 失败!" >&2
    fi
  done <<< "$NODES"

  echo
done

echo "=== 全部镜像加载完毕 ==="

# 验证：在每个节点上列出刚导入的镜像
echo
echo "=== 验证: 各节点容器运行时镜像列表 ==="
while IFS= read -r node; do
  [[ -z "$node" ]] && continue
  echo "--- $node ---"
  docker exec "$node" crictl images 2>/dev/null | head -20
  echo
done <<< "$NODES"
