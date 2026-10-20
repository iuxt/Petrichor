# Petrichor 官网

使用 Hugo 构建的中文产品介绍页，部署到 <https://iuxt.github.io/Petrichor/>。

## 本地预览

在仓库根目录运行（Hugo 0.168.0）：

```sh
hugo server --source website
```

打开终端输出的本地地址。生产构建：

```sh
hugo --source website --gc --minify --panicOnWarning
```

输出目录是 `website/public/`，无需提交。没有 Node.js、外部主题、外部字体或 JavaScript 运行时依赖。

## 内容和素材

- `hugo.toml`：站点地址、描述、下载地址和系统要求。
- `layouts/home.html`：首页文案和章节。
- `layouts/baseof.html`：导航、页脚与 SEO 元数据。
- `assets/css/main.css`：响应式样式，含键盘焦点和减少动态效果支持。
- `layouts/partials/screenshot.html`：使用 Hugo 自动生成响应式 WebP 截图。

通过 Hugo module mounts 直接复用仓库的 `docs/images/` 和 `Resources/Brand/`，无需复制素材；因此请在完整仓库中构建。网站内容与 macOS 应用本地化独立维护。

## GitHub Pages

1. 仓库 **Settings → Pages → Build and deployment → Source** 选择 **GitHub Actions**。
2. 将变更推送到 `main`。`.github/workflows/website.yml` 会构建并部署官网，也支持从 Actions 页面手动触发。
3. 工作流只在官网、共享图片或部署配置变化时运行，不影响应用的 Release 打包流程。

工作流从 Pages 获取实际 `baseURL`，所有本地资源和首页锚点支持项目子路径。改用自定义域名时，在 Pages 设置域名并同步修改 `hugo.toml` 的默认地址。

部署方式参考 [Hugo 官方 GitHub Pages 文档](https://gohugo.io/host-and-deploy/deploy-to-github-pages/)。
