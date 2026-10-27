set -e

# 自动同步 TheosRuntime 环境变量，确保可调用 lipo 等底层工具
if [ -z "$THEOS" ]; then
    CODEX_COMPAT=$(echo "$PATH" | grep -o '[^:]*TheosCoreCompat' | head -n 1)
    if [ -n "$CODEX_COMPAT" ]; then
        CODEX_APP="${CODEX_COMPAT%/Helpers/TheosCoreCompat}"
        export THEOS="$CODEX_APP/TheosRuntime/theos"
        export PATH="$CODEX_APP/TheosRuntime/usr/bin:$CODEX_APP/TheosRuntime/usr/lib/llvm-16/bin:$CODEX_APP/TheosRuntime/theos/bin:$CODEX_APP/TheosRuntime/bin:$PATH"
    fi
fi

ACTION="${1:-build}"

# 自动同步 TheosRuntime 与 OLLVM 环境变量，确保可调用底层工具与混淆编译器
if [ -z "$THEOS" ] || [ -z "$CA_TOOL_OLLVM_CLANG" ]; then
    CODEX_COMPAT=$(echo "$PATH" | grep -o '[^:]*TheosCoreCompat' | head -n 1)
    if [ -n "$CODEX_COMPAT" ]; then
        CODEX_APP="${CODEX_COMPAT%/Helpers/TheosCoreCompat}"
        [ -z "$THEOS" ] && export THEOS="$CODEX_APP/TheosRuntime/theos"
        export PATH="$CODEX_APP/TheosRuntime/usr/bin:$CODEX_APP/TheosRuntime/usr/lib/llvm-16/bin:$CODEX_APP/TheosRuntime/theos/bin:$CODEX_APP/TheosRuntime/bin:$PATH"
        [ -z "$CA_TOOL_OLLVM_CLANG" ] && export CA_TOOL_OLLVM_CLANG="$CODEX_APP/ManagedRuntimes/ollvm/bin/clang"
        [ -z "$TARGET_LD" ] && export TARGET_LD="$CODEX_APP/TheosRuntime/usr/lib/llvm-16/bin/clang-16"
        [ -z "$CA_TOOL_OLLVM_RESOURCE_DIR" ] && export CA_TOOL_OLLVM_RESOURCE_DIR="$CODEX_APP/ManagedRuntimes/ollvm/lib/clang/16"
    fi
fi

case "$ACTION" in
    build|b)
        echo "==> [清理缓存] 确保无历史缓存污染..."
        make clean
        echo "==> 正在编译双架构 dylib..."
        make
        if [ -f "dist/PVZSun.dylib" ]; then
            echo "==> 架构切片验证："
            lipo -info dist/PVZSun.dylib
            echo "==> 产物文件详情："
            ls -lh dist/
        fi
        ;;
    deb|package|pkg|p)
        echo "==> [清理缓存] 确保无历史缓存污染..."
        make clean
        echo "==> 正在编译并打包 DEB 安装包..."
        make package FINALPACKAGE=1 ${THEOS_PACKAGE_SCHEME:+THEOS_PACKAGE_SCHEME=$THEOS_PACKAGE_SCHEME}
        echo "==> 最新 DEB 包："
        ls -lh packages/*.deb 2>/dev/null || true
        ;;
    rootful|rf)
        echo "==> [清理缓存] 确保无历史缓存污染..."
        make clean
        echo "==> 正在编译并打包 [Rootful 有根越狱] DEB 安装包 (/Library/...)..."
        make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=
        echo "==> 架构切片验证："
        lipo -info dist/PVZSun.dylib
        echo "==> 最新 Rootful DEB 包："
        ls -lh packages/*.deb 2>/dev/null || true
        ;;
    rootless|rl)
        echo "==> [清理缓存] 确保无历史缓存污染..."
        make clean
        echo "==> 正在编译并打包 [Rootless 无根越狱] DEB 安装包 (/var/jb/...)..."
        make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
        echo "==> 架构切片验证："
        lipo -info dist/PVZSun.dylib
        echo "==> 最新 Rootless DEB 包："
        ls -lh packages/*.deb 2>/dev/null || true
        ;;
    roothide|rh)
        echo "==> [清理缓存] 确保无历史缓存污染..."
        make clean
        echo "==> 正在编译并打包 [RootHide 隐藏越狱] DEB 安装包 (.jbroot)..."
        make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
        echo "==> 架构切片验证："
        lipo -info dist/PVZSun.dylib
        echo "==> 最新 RootHide DEB 包："
        ls -lh packages/*.deb 2>/dev/null || true
        ;;
    obf|ollvm)
        echo "==> [清理缓存] 强制清理历史中间文件，确保混淆编译完整生效..."
        make clean
        echo "==> 正在使用 OLLVM 混淆构建双架构安装包 (含 PAC 硬件兼容)..."
        make package ARCHS="arm64 arm64e" \
            TARGET_CC="${TARGET_CC:-$CA_TOOL_OLLVM_CLANG}" \
            TARGET_CXX="${TARGET_CXX:-${CA_TOOL_OLLVM_CLANG}++}" \
            TARGET_LD="${TARGET_LD}" \
            FINALPACKAGE=1
        echo "==> 架构切片验证："
        lipo -info dist/PVZSun.dylib
        echo "==> 最新混淆产物："
        ls -lh dist/
        ls -lh packages/*.deb 2>/dev/null || true
        ;;
    obf-dylib|obfd)
        echo "==> [清理缓存] 强制清理历史中间文件，确保混淆编译完整生效..."
        make clean
        echo "==> 正在使用 OLLVM 混淆仅编译双架构 dylib..."
        make ARCHS="arm64 arm64e" \
            TARGET_CC="${TARGET_CC:-$CA_TOOL_OLLVM_CLANG}" \
            TARGET_CXX="${TARGET_CXX:-${CA_TOOL_OLLVM_CLANG}++}" \
            TARGET_LD="${TARGET_LD}"
        echo "==> 架构切片验证："
        lipo -info dist/PVZSun.dylib
        echo "==> 产物详情："
        ls -lh dist/
        ;;
    clean|c)
        echo "==> 正在清理构建缓存..."
        make clean
        ;;
    check|info)
        echo "==> 检查当前产物状态："
        if [ -f "dist/PVZSun.dylib" ]; then
            lipo -info dist/PVZSun.dylib
            ls -lh dist/
        else
            echo "提示: 未发现 dist/PVZSun.dylib"
        fi
        if [ -d "packages" ]; then
            echo "==> DEB 目录状态："
            ls -lh packages/*.deb 2>/dev/null || true
        fi
        ;;
    help|-h|--help)
        echo "=========================================="
        echo "  植物大战僵尸辅助插件构建脚本"
        echo "=========================================="
        echo "用法: ./build.sh [命令]"
        echo ""
        echo "可用命令:"
        echo "  build (默认)    自动清理旧缓存并编译双架构 dylib"
        echo "  rootful (rf)    编译打包 [Rootful 有根越狱] DEB 安装包 (传统 /Library/ 路径)"
        echo "  rootless (rl)   编译打包 [Rootless 无根越狱] DEB 安装包 (/var/jb/ 路径)"
        echo "  roothide (rh)   编译打包 [RootHide 隐藏越狱] 原生 DEB 安装包 (.jbroot 架构)"
        echo "  deb             通用打包命令 (根据环境 THEOS_PACKAGE_SCHEME 打包)"
        echo "  obf             自动清理旧缓存，使用 OLLVM 混淆构建双架构 deb 包"
        echo "  obf-dylib       自动清理旧缓存，使用 OLLVM 混淆仅编译双架构 dylib"
        echo "  clean           清理 Theos 编译中间缓存"
        echo "  check           查看当前产物切片架构与文件详情"
        echo "  help            显示本帮助信息"
        echo "=========================================="
        ;;
    *)
        echo "错误: 未知参数 '$ACTION'"
        echo "执行 './build.sh help' 查看可用参数"
        exit 1
        ;;
esac
