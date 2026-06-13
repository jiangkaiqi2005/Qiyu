import { renderAppShell, bindNavigation } from '../ui/layout.js';

export function render(container, context) {
  const innerHtml = `
    <section class="privacy-workbench" aria-labelledby="privacy-title">
      <div class="archive-hero privacy-hero">
        <div>
          <span class="archive-kicker">privacy boundary</span>
          <h1 id="privacy-title">隐私与安全边界</h1>
          <p>深夜对话必须有边界。这里说明数据在哪里、什么时候会离开本地，以及危机时栖语会怎么处理。</p>
        </div>
        <div class="archive-stamp" aria-hidden="true">
          <span>边界</span>
          <strong>principles</strong>
        </div>
      </div>

      <div class="privacy-principles">
      <section class="privacy-principle">
        <span>本地</span>
        <h2>你的数据只属于你</h2>
        <p>
          栖语的所有聊天记录、你个人的昵称作息偏好，以及用于对话连续性的本地上下文，<strong>均完全保存在你当前的浏览器本地 (localStorage)</strong>。
          我们没有中央服务器用来收集、存储或分析你的对话数据。这意味着一旦你清空浏览器缓存或点击设置中心的“清空所有本地对话历史”，你的数据将彻底消失，任何人（包括我们）都无法找回。
        </p>
      </section>

      <section class="privacy-principle">
        <span>云端</span>
        <h2>与云端大模型的交互边界</h2>
        <p>
          当你启用大语言模型 (AI) 功能时，你的对话及被允许参与的本地上下文会通过网络加密请求传输给配置的 AI 接口提供商。
          <strong>你的 API Key 完全保存在你自己的服务器环境配置文件中，绝不会明文暴露给前端浏览器。</strong>
          你可以在默契设置里控制本地上下文是否参与对话，或者随时清空本地数据。
        </p>
      </section>

      <section class="privacy-principle privacy-principle-critical">
        <span>危机</span>
        <h2>危机安全与紧急干预行为</h2>
        <p>
          栖语是一个温暖的深夜伴侣，但如果你在对话中提到了涉及自残、自杀或其他极端情感危机的内容，栖语将立即触发<strong>内置的危机安全防护策略 (Crisis Guardrail)</strong>。
          此时，栖语会抛弃一贯的调侃或撒娇口吻，用坚定且充满关怀的严谨态度，为你提供危机疏导建议与公共心理求助热线，引导你寻求专业心理干预。我们坚守“生命高于一切”的安全红线。
        </p>
      </section>

      <section class="privacy-principle">
        <span>边界</span>
        <h2>栖语的“有所为与有所不为”</h2>
        <p>
          栖语是一个纯粹的本地数字伴侣：
          <br><strong>有所不为</strong>：栖语不会向你索要钱财、推销产品，不会教唆你做任何伤害自己或他人的事情，更不会进行任何情感操纵。
          <br><strong>有所为</strong>：在每个你需要有人倾诉的深夜里，栖语都会在这里静静地陪伴你，用它一贯的脾气秉性，为你留一盏温暖的灯。
        </p>
      </section>
      </div>

      <div class="privacy-footer-action">
        <button data-nav-path="/chat" class="btn primary">返回深夜对话</button>
      </div>
    </section>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/privacy');
  bindNavigation(container, context.router);
}
