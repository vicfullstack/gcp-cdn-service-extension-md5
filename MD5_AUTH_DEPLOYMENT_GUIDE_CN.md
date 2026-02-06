# MD5 身份验证服务扩展部署指南

本指南记录了 Google Cloud Service Extension（边缘扩展）的开发、基础设施设置和部署过程，该扩展实现了基于 MD5 的 URL 身份验证。

## 1. 流程概述

Service Extensions（特别是 [Edge Extensions](https://docs.cloud.google.com/service-extensions/docs/lb-extensions-overview?hl=en)）允许您将自定义逻辑注入到 Google Cloud 应用负载均衡器的请求处理路径中。此功能由运行在边缘的 **WebAssembly (Wasm)** 插件提供支持，这些插件会在流量到达后端服务或 Cloud CDN 缓存**之前**拦截流量。

在本实施方案中，我们将基于 Rust 的 Wasm 插件部署到**应用负载均衡器**。该插件拦截传入的 HTTP 请求，从 URL 中提取身份验证令牌，并根据安全的 MD5 签名逻辑对其进行验证。这种模式广泛用于媒体流（例如，防止盗链），以确保只有持有有效、未过期令牌的授权用户才能访问内容。

## 2. 解决方案规范

该解决方案强制执行一项安全策略，要求对负载均衡器的每个请求都必须包含有效的 `auth_key` 查询参数。此密钥通过验证过期时间和数字签名来保护内容。

**URL 格式：**
```
http://<LB_IP>/<path>?auth_key=<timestamp>-<rand>-<uid>-<md5hash>
```

**签名逻辑：**
```
md5hash = MD5(/path-timestamp-rand-uid-secret_key)
```

## 3. 插件开发

逻辑使用 Rust 语言和 `proxy-wasm` SDK 实现，该 SDK 编译为 WebAssembly (Wasm) 模块。

### 核心逻辑 (`md5_plugin/src/lib.rs`)

插件拦截 HTTP 请求头并执行以下检查：
1.  从查询字符串中**提取** `auth_key`。
2.  将密钥**解析**为其组件：`timestamp`（时间戳）、`rand`（随机数）、`uid`（用户ID）和 `hash`（哈希值）。
3.  **验证过期时间**：检查当前时间是否大于提供的 `timestamp`。
4.  **验证签名**：使用请求路径、参数和共享的 `secret_key`（部署时配置）重新计算 MD5 哈希。如果计算出的哈希与提供的哈希匹配，则允许请求；否则，将以 `403 Forbidden` 拒绝请求。

### 依赖项 (`md5_plugin/Cargo.toml`)
- `proxy-wasm`: Google 用于编写 Wasm 扩展的 SDK。
- `md5`: 用于加密哈希。
- `url`: 用于稳健的 URL 解析。

## 4. 基础设施设置

Service Extensions 需要使用 **`EXTERNAL_MANAGED`** 负载均衡方案的**应用负载均衡器**。不支持传统的外部负载均衡器。

### 已创建的组件
1.  **托管后端服务** (`nginx-uig-hk-managed`)：
    - 协议：HTTP
    - 负载均衡方案：`EXTERNAL_MANAGED`
    - 后端：实例组 `nginx-uig-hk`
2.  **URL 映射** (`md5-lb-map`)：将请求路由到后端服务。
3.  **目标 HTTP 代理** (`md5-lb-proxy`)：转发规则的辅助组件。
4.  **转发规则** (`md5-lb-forwarding-rule`)：流量的入口点（IP：`34.117.49.78`）。
5.  **防火墙规则** (`allow-health-checks`)：允许 Google 健康检查探测器（IP 范围 `130.211.0.0/22`，`35.191.0.0/16`）在端口 80 上访问后端虚拟机。

## 5. 部署步骤

部署过程通过 `deploy.sh` 自动化。关键步骤包括：

1.  **构建 Wasm**：将 Rust 代码编译为 `wasm32-wasip1` 目标。
    ```bash
    cargo build --release --target wasm32-wasip1
    ```

2.  **容器化**：将 `.wasm` 文件打包到最小化的 Docker 容器中（`FROM scratch`）。

3.  **上传**：将容器镜像推送到 Google Artifact Registry。
    ```bash
    docker push us-central1-docker.pkg.dev/vicdemo/service-extensions/md5-auth-plugin:v1
    ```

4.  **创建插件资源**：向 Google Cloud Service Extensions 注册插件。
    ```bash
    gcloud service-extensions wasm-plugins create md5-auth-plugin ...
    ```

5.  **导入边缘扩展**：使用 YAML 配置将插件绑定到负载均衡器的转发规则。
    ```yaml
    name: md5-edge-extension
    forwardingRules:
    - projects/vicdemo/global/forwardingRules/md5-lb-forwarding-rule
    loadBalancingScheme: EXTERNAL_MANAGED
    extensionChains:
    - name: "md5-chain"
      matchCondition:
        celExpression: 'request.path.startsWith("/")'
      extensions:
      - name: 'md5-auth'
        service: .../wasmPlugins/md5-auth-plugin
        supportedEvents:
        - REQUEST_HEADERS
    ```

## 6. 验证

验证是通过一个 Python 脚本 (`test_md5.py`) 执行的，该脚本生成有效和无效的令牌。

**测试用例：**
- **有效请求**：`200 OK`（签名匹配，令牌未过期）。
- **过期令牌**：`403 Forbidden`（令牌时间戳已过去）。
- **无效密钥**：`403 Forbidden`（由于密钥错误导致签名不匹配）。
- **路径不匹配**：`403 Forbidden`（针对一个文件的有效签名不能用于另一个文件）。

### 如何生成令牌 (Python 示例)
```python
import hashlib
import time

def generate_url(ip, path, secret):
    # 时间戳：未来 1 小时
    timestamp = int(time.time()) + 3600
    rand = "12345"
    uid = "0"
    
    # 签名字符串：/path-timestamp-rand-uid-secret
    # 注意：确保 'path' 以 / 开头
    string_to_hash = f"{path}-{timestamp}-{rand}-{uid}-{secret}"
    md5_hash = hashlib.md5(string_to_hash.encode('utf-8')).hexdigest()
    
    auth_key = f"{timestamp}-{rand}-{uid}-{md5_hash}"
    return f"http://{ip}{path}?auth_key={auth_key}"
```
