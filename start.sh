#!/system/bin/sh

error_exit() {
    setprop persist.sys.oplus.nandswap.condition false
    setprop sys.oplus.nandswap.init false
    exit 1
}

#初始化prop
setprop persist.sys.oplus.nandswap true
setprop persist.sys.oplus.nandswap.condition true
setprop sys.oplus.nandswap.init false

echo "===== 校验 ROOT ====="
if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root 权限"
    error_exit
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$SCRIPT_DIR/hybridswap.conf"

# "===== 默认配置 ====="
ZRAM_MB=7168
NANDSWAP_MB=3072
COMP_ALG=zstd
SWAPFILE=/data/nandswap/swapfile
memcg=default
vm_swappiness=200
hybridswapd_swappiness=200
direct_vm_swappiness=60
parameters=/sys/module/zram_opt/parameters

echo "===== 读取配置文件 ====="
[ -f "$CONF_FILE" ]

conf_zram=$(grep '^zram=' "$CONF_FILE" | cut -d '=' -f2)
case "$conf_zram" in
    ''|[!0-9]) ;;
    *) ZRAM_MB=$conf_zram ;;
esac

conf_swap=$(grep '^nandswap=' "$CONF_FILE" | cut -d '=' -f2)
case "$conf_swap" in
    ''|[!0-9]) ;;
    *) NANDSWAP_MB=$conf_swap ;;
esac

conf_comp=$(grep '^comp=' "$CONF_FILE" | cut -d '=' -f2)
COMP_ALG=$conf_comp

conf_memcg=$(grep '^memcg=' "$CONF_FILE" | cut -d '=' -f2)

vm_swappiness=$(grep '^vm_swappiness=' "$CONF_FILE" | cut -d '=' -f2)
hybridswapd_swappiness=$(grep '^hybridswapd_swappiness=' "$CONF_FILE" | cut -d '=' -f2)
direct_vm_swappiness=$(grep '^direct_vm_swappiness=' "$CONF_FILE" | cut -d '=' -f2)

echo "===== 验证压缩算法 ====="
avail=$(cat /sys/block/zram0/comp_algorithm)
if ! echo "$avail" | grep -qw "$COMP_ALG"; then
    echo "[×] 不支持压缩算法 $COMP_ALG"
    error_exit
fi

echo "===== 验证memcg配置 ====="
mcg="active basic default"
if ! echo "$mcg" | grep -qw "$conf_memcg"; then
    echo "[×] 错误！查看你的配置文件中的memcg是否填写正确！"
    error_exit
fi

echo "===== 初始化 ZRAM ====="
echo "[+] 设置 ZRAM: ${ZRAM_MB}MB 使用 $COMP_ALG"
echo 4 > /sys/block/zram0/max_comp_streams
sync
swapoff /dev/block/zram0 >/dev/null 2>&1
echo 1 > /sys/block/zram0/reset
echo 0 > /sys/block/zram0/disksize
echo "$COMP_ALG" > /sys/block/zram0/comp_algorithm
#echo "${ZRAM_MB} * 1024 " > /sys/block/zram0/disksize
#echo $((ZRAM_MB * 1024 * 1024)) > /sys/block/zram0/disksize
disksize=$(expr $ZRAM_MB \* 1024 \* 1024)
echo $disksize > /sys/block/zram0/disksize
mkswap /dev/block/zram0
swapon /dev/block/zram0 -p 32758

echo "===== 准备 swapfile 并分配 loop ====="
echo "[+] 分配 ${NANDSWAP_MB}MB swapfile"
mkdir -p "$(dirname "$SWAPFILE")"
fallocate -l "${NANDSWAP_MB}M" "$SWAPFILE"

for loopdev in $(losetup -j "$SWAPFILE" 2>/dev/null | awk -F: '{print $1}'); do
    losetup -d "$loopdev" 2>/dev/null && echo "[+] 已解绑旧设备: $loopdev"
done

loopdev=$(losetup -f)
if [ -z "$loopdev" ]; then
    echo "[×] 没有可用的 loop 设备"
    error_exit
fi

if ! losetup "$loopdev" "$SWAPFILE"; then
    echo "[×] 绑定 loop 设备失败: $loopdev"
    error_exit
fi

echo "[+] 成功绑定 loop 设备: $loopdev"

echo "===== 启用 hybridswap ====="
echo "[+] hybridswap => $loopdev"
echo "$loopdev" > /sys/block/zram0/hybridswap_loop_device || {
    echo "[×] 写入 hybridswap_loop_device 失败"
    error_exit
}
echo 1 > /sys/block/zram0/hybridswap_enable || {
    echo "[×] 启用 hybridswap 失败"
    error_exit
}

echo "===== 配置 memcg 参数（可选） ====="
if echo "$conf_memcg" | grep -qw 'active'; then
  echo "[+] 设置 active 策略..."
  echo "4 0 99 50 0 1 100 399 60 30 2 400 499 20 60 3 500 1000 10 90" > /dev/memcg/memory.swapd_memcgs_param
elif echo "$conf_memcg" | grep -qw 'basic'; then
  echo "[+] 设置 basic 策略..."
  echo "3 0 199 60 0 1 200 699 40 30 2 700 1000 10 60" > /dev/memcg/memory.swapd_memcgs_param
else 
  echo "memcg策略为系统默认"
fi
echo 20480 > /dev/memcg/memory.swapd_max_direct_pages
HYB_MAX_BYTES=$(( NANDSWAP_MB * 1024 * 1024 ))
echo "$HYB_MAX_BYTES" > /dev/memcg/memory.hybridswap_max_bytes

# "===== 交换率相关 ====="
echo $vm_swappiness > $parameters/vm_swappiness 
echo $hybridswapd_swappiness > $parameters/hybridswapd_swappiness 
echo $direct_vm_swappiness > $parameters/direct_vm_swappiness

# "===== 显示状态 ====="
echo "[√] hybridswap 启动完成"
echo "当前压缩算法：$COMP_ALG"
echo "当前 loop 设备：$loopdev"
echo "ZRAM 大小：${ZRAM_MB}MB"
echo "NANDSwap 大小：${NANDSWAP_MB}MB"
echo "hybridswapd_swappiness=$hybridswapd_swappiness"
echo "vm_swappiness=$vm_swappiness"
echo "direct_vm_swappiness=$direct_vm_swappiness"

cat /sys/block/zram0/hybridswap_stat_snap 2>/dev/null | sed 's/EST:/回写块总容量:/; s/ESU_C:/swap已用(压缩):/; s/ESU_O:/swap已用(原始):/; s/ZST:/ZRAM总容量:/; s/ZST_C:/ZRAM已用(压缩):/; s/ZST_O:/ZRAM已用(原始):/' | grep -E '回写块总容量:|swap已用|ZRAM总容量:|ZRAM已用'
