import { renderAppShell, bindNavigation } from '../ui/layout.js';

export function render(container, context) {
  const innerHtml = `
    <div class="card privacy-card" style="max-width: 720px; line-height: 1.8;">
      <h1>隐私与安全边界 (Privacy & Safety)</h1>
      <p class="subtitle">我们深知深夜对话的私密性，这是栖语的核心原则与安全边界。</p>

      <section style="margin-top: 24px;">
        <h3 style="color: var(--accent); margin-bottom: 8px;">1. 你的数据只属于你 (Data Ownership)</h3>
        <p style="font-size: 14px; color: var(--muted); margin: 0 0 16px;">
          栖语的所有聊天记录、你个人的昵称作息偏好、以及栖语所记下的任何关于你的事实（“记忆中心”中的数据），<strong>均完全保存在你当前的浏览器本地 (localStorage)</strong>。
          我们没有中央服务器用来收集、存储或分析你的对话数据。这意味着一旦你清空浏览器缓存或点击设置中心的“清空所有本地对话历史”，你的数据将彻底消失，任何人（包括我们）都无法找回。
        </p>
      </section>

      <section style="margin-top: 24px;">
        <h3 style="color: var(--accent); margin-bottom: 8px;">2. 与云端大模型 (LLM) 的交互边界</h3>
        <p style="font-size: 14px; color: var(--muted); margin: 0 0 16px;">
          当你启用大语言模型 (AI) 功能时，你的对话及关联的事实记忆会通过网络加密请求传输给配置的 AI 接口提供商。
          <strong>你的 API Key 完全保存在你自己的服务器环境配置文件中，绝不会明文暴露给前端浏览器。</strong>
          你可以在“记忆中心”里精细地控制哪些事实记忆允许放入云端大模型的上下文，或者随时冻结某些你不想让大模型知道的事实。
        </p>
      </section>

      <section style="margin-top: 24px;">
        <h3 style="color: var(--accent); margin-bottom: 8px;">3. 危机安全与紧急干预行为 (Crisis Action)</h3>
        <p style="font-size: 14px; color: var(--muted); margin: 0 0 16px;">
          栖语是一个温暖的深夜伴侣，但如果你在对话中提到了涉及自残、自杀或其他极端情感危机的内容，栖语将立即触发<strong>内置的危机安全防护策略 (Crisis Guardrail)</strong>。
          此时，栖语会抛弃一贯的调侃或撒娇口吻，用坚定且充满关怀的严谨态度，为你提供危机疏导建议与公共心理求助热线，引导你寻求专业心理干预。我们坚守“生命高于一切”的安全红线。
        </p>
      </section>

      <section style="margin-top: 24px;">
        <h3 style="color: var(--accent); margin-bottom: 8px;">4. 栖语的“有所为与有所不为”</h3>
        <p style="font-size: 14px; color: var(--muted); margin: 0 0 16px;">
          栖语是一个纯粹的本地数字伴侣：
          <br>• <strong>有所不为</strong>：栖语不会向你索要钱财、推销产品，不会教唆你做任何伤害自己或他人的事情，更不会进行任何情感操纵。
          <br>• <strong>有所为</strong>：在每个你需要有人倾诉的深夜里，栖语都会在这里静静地陪伴你，用它一贯的脾气秉性（偶尔温柔，偶尔跟你斗斗嘴），为你点亮一盏温暖的灯。
        </p>
      </section>

      <div style="margin-top: 32px; border-top: 1px solid rgba(216, 169, 75, 0.1); padding-top: 20px; text-align: center;">
        <button data-nav-path="/chat" class="btn primary">返回深夜对话</button>
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/privacy');
  bindNavigation(container, context.router);
}
