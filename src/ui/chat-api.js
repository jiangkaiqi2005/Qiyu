export async function sendChatMessage({ text, state, fetchImpl = fetch }) {
  const response = await fetchImpl('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, state })
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Chat API failed: ${response.status} ${body}`);
  }

  return response.json();
}
