const app = document.querySelector('#app');

app.innerHTML = `
  <main class="shell">
    <section class="thread" aria-label="栖语对话">
      <p class="qiyu">嗨。我是栖语。</p>
    </section>
    <form class="composer" aria-label="发送消息">
      <input name="message" autocomplete="off" placeholder="今天过得怎么样">
      <button type="submit">发送</button>
    </form>
  </main>
`;
