import 'package:flutter/widgets.dart';

import '../shell/qiyu_ui_locale.dart';

/// A paired setting label. Keeping both variants at the call site makes a
/// newly added label require its English counterpart immediately.
String settingsText(BuildContext context, String zh, String en) =>
    qiyuIsEn(context) ? en : zh;

/// Use from event handlers and asynchronous actions, outside build.
String settingsTextNow(BuildContext context, String zh, String en) =>
    qiyuIsEnNow(context) ? en : zh;

String settingsDisplayMessage(BuildContext context, String message) =>
    qiyuIsEn(context) ? _englishMessage(message) : message;

String settingsDisplayMessageNow(BuildContext context, String message) =>
    qiyuIsEnNow(context) ? _englishMessage(message) : message;

String _englishMessage(String message) {
  final fixed = _messageEnglish[message];
  if (fixed != null) return fixed;
  for (final service in const <String, String>{
    '模型服务': 'model service',
    '语音服务': 'voice service',
    '语音合成服务': 'speech synthesis service',
  }.entries) {
    final zh = service.key;
    final en = service.value;
    if (message == '找不到$zh域名，请检查地址或 DNS。') return 'Could not resolve the $en. Check the URL or DNS.';
    if (message == '$zh的 TLS 安全连接失败。') return 'The $en TLS connection failed.';
    if (message == '连接$zh超时。') return 'The $en connection timed out.';
    if (message == '无法连接$zh，请检查地址和网络。') return 'Could not connect to the $en. Check the URL and network.';
    if (message == '$zh请求过于频繁，请稍后再试。') return 'Too many $en requests. Try again later.';
    if (message == '$zh返回了不兼容的响应格式。') return 'The $en returned an incompatible response format.';
    if (message == '$zh返回的内容无法解析。') return 'Could not parse the $en response.';
    if (message == '$zh拒绝了测试请求。') return 'The $en rejected the test request.';
  }
  return message;
}

String settingsSuggestionLineNow(BuildContext context, String line) {
  if (!qiyuIsEnNow(context)) return line;
  var translated = line
      .replaceAll('服务类型：', 'Service type: ')
      .replaceAll('模型名称：', 'Model name: ')
      .replaceAll('服务地址：填入官方推理地址', 'Service URL: use official inference URL')
      .replaceAll('服务地址：填入建议地址', 'Service URL: use suggested URL')
      .replaceAll('服务地址：填入官方地址模板', 'Service URL: use official URL template')
      .replaceAll('服务地址：保持不变；保存测试前请按卡片指引把地址换成新版端点', 'Service URL: unchanged; use the newer endpoint shown on the card before saving and testing')
      .replaceAll('服务地址：不变', 'Service URL: unchanged')
      .replaceAll('把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID 后再保存', 'Replace {业务空间ID} with your own Alibaba Cloud Bailian workspace ID before saving')
      .replaceAll('API Key：清空重填，切换服务不沿用旧 Key', 'API key: clear and re-enter; the saved key is not reused for another service')
      .replaceAll('API Key：地址变更保存后 Key 需重填（已保存的 Key 不沿用新地址）', 'API key: re-enter after saving the new URL; the old key is not reused')
      .replaceAll('API Key：保留已保存的 Key；地址换成新版端点保存时，Key 按既有规则需重填', 'API key: keep the saved key for now; re-enter it when saving the newer endpoint')
      .replaceAll('API Key：保留', 'API key: keep')
      .replaceAll('（空）', '(empty)');
  for (final label in _catalogEnglish.entries) {
    translated = translated.replaceAll(label.key, label.value);
  }
  return translated;
}

const _messageEnglish = <String, String>{
  '已保存到本机。': 'Saved locally.',
  '请检查 temperature 和超时时间。': 'Check the temperature and timeout values.',
  '请填写服务地址和模型名称。': 'Enter the service URL and model name.',
  '代理地址填主机名或 IP 即可，不带 http:// 前缀。': 'Enter a hostname or IP for the proxy, without an http:// prefix.',
  '启用代理时请填写代理地址。': 'Enter a proxy host to enable the proxy.',
  '请先填写代理地址，再填写代理端口。': 'Enter the proxy host before the port.',
  '请填写 1 到 65535 之间的代理端口。': 'Enter a proxy port between 1 and 65535.',
  '请填写语音合成服务地址和模型名称。': 'Enter the speech synthesis URL and model name.',
  '请填写语音服务地址和模型名称。': 'Enter the speech service URL and model name.',
  '自定义高级参数必须是 JSON 对象。': 'Custom parameters must be a JSON object.',
  '自定义高级参数 JSON 格式不正确，请检查语法。': 'Check the syntax of the custom JSON parameters.',
  '联网搜索设置暂时不可用，请稍后重试。': 'Web search settings are temporarily unavailable. Try again later.',
  '模型设置暂时不可用，请稍后重试。': 'Model settings are temporarily unavailable. Try again later.',
  '语音朗读设置暂时不可用，请稍后重试。': 'Read aloud settings are temporarily unavailable. Try again later.',
  '语音设置暂时不可用，请稍后重试。': 'Voice settings are temporarily unavailable. Try again later.',
  '设置服务暂时不可用，请稍后重试。': 'Settings are temporarily unavailable. Try again later.',
  '代理设置暂时不可用，请稍后重试。': 'Proxy settings are temporarily unavailable. Try again later.',
  '试听已停止，请主动重试。': 'Preview stopped. Try again when ready.',
  '语音服务已连接，但本机没能播放试听。点「再听一次试听」重试。': 'The speech service connected, but the preview did not play locally. Tap “Replay preview” to try again.',
  '连接成功，栖语可以使用这个模型。': 'Connected. Qiyu can use this model.',
  '连接成功，语音输入可以使用。': 'Connected. Voice input is available.',
  '连接成功，语音朗读可以使用。': 'Connected. Read aloud is available.',
  '连接成功，点「听试听」可以听听栖语的声音。': 'Connected. Play the preview to hear Qiyu’s voice.',
  '还没有保存模型配置。': 'No model configuration has been saved.',
  '还没有保存语音服务配置。': 'No voice service configuration has been saved.',
  '还没有保存语音合成服务配置。': 'No speech synthesis configuration has been saved.',
  'API Key 没有通过验证。': 'The API key could not be verified.',
  '找不到这个模型，请检查模型名称。': 'Model not found. Check the model name.',
  '这个模型不能用当前服务地址调用，请更换模型或调整服务地址。': 'This model cannot be called through the current service URL. Change the model or URL.',
  '本机程序内部出错，请重试或重启栖语。': 'The local app encountered an error. Try again or restart Qiyu.',
  '这个型号是统一音频生成型号，官方没有给朗读用的通道，栖语接不了它。': 'This is a unified audio generation model without an official read-aloud channel that Qiyu can use.',
  '这个型号是端到端语音对话型号，不归转写或朗读用，栖语接不了它。': 'This is an end-to-end voice conversation model, not a transcription or read-aloud model Qiyu can use.',
  '这个型号要边说边传的流式识别通道，栖语暂不支持。': 'This model needs streaming recognition while you speak, which Qiyu does not support yet.',
  '这是录音文件转写型号，栖语不支持。': 'This is an audio-file transcription model that Qiyu does not support.',
  '这个型号要走千问朗读档。': 'This model needs the Qwen read-aloud service.',
  '这个型号要走千问识别档。': 'This model needs the Qwen recognition service.',
  '这个型号要走千问朗读档的新版语音通道。': 'This model needs the newer Qwen read-aloud channel.',
  '把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID 后整条填入服务地址，新版端点需要自有百炼 Key。型号支持范围见阿里云百炼官方模型页：https://help.aliyun.com/zh/model-studio/qwen-tts': 'Replace {业务空间ID} with your own Alibaba Cloud Bailian workspace ID and enter the full service URL. The newer endpoint needs your own Bailian key. Supported models: https://help.aliyun.com/zh/model-studio/qwen-tts',
};

/// Provider and voice catalog labels are display names. IDs and stored values
/// remain unchanged across language switches.
String settingsCatalogLabel(BuildContext context, String label) {
  if (!qiyuIsEn(context)) return label;
  if (label.startsWith('支持 HTTP 非流式识别模型，如 ')) {
    return 'Supports non-streaming HTTP recognition models, e.g. ${label.substring('支持 HTTP 非流式识别模型，如 '.length)}';
  }
  if (label.startsWith('流式合成型号：')) {
    return label
        .replaceAll('流式合成型号：', 'Streaming synthesis models: ')
        .replaceAll('（HTTP SSE，边出文字边出声）', ' (HTTP SSE; speech starts as text arrives)')
        .replaceAll('（WebSocket，前几个字就出声）', ' (WebSocket; speech starts after the first few characters)')
        .replaceAll('3.x 新型号（', 'New 3.x models (')
        .replaceAll(' 等）走官方新版语音通道：服务地址直接填 ', ' etc.) use the new official speech channel. Set the service URL to ')
        .replaceAll('（推理通道按句流式）；也可填官方 maas HTTP 端点 ', ' (sentence-level streaming inference); or use the official maas HTTP endpoint ')
        .replaceAll('，把 {业务空间ID} 换成你自己的阿里云百炼业务空间 ID（栖语不代填，按句等整段返回）；型号支持范围见官方模型页：', '. Replace {业务空间ID} with your own Alibaba Cloud Bailian workspace ID (Qiyu will not fill it; each sentence waits for its complete audio). Supported models: ');
  }
  return _catalogEnglish[label] ?? label;
}

String settingsVoiceDescription(
  BuildContext context,
  String family,
  String wireName,
  String original,
) => qiyuIsEn(context)
    ? _voiceDescriptions['$family:$wireName'] ?? original
    : original;

String settingsVoiceExample(
  BuildContext context,
  String family,
  String wireName,
  String original,
) => qiyuIsEn(context)
    ? _voiceExamples['$family:$wireName'] ?? original
    : original;

const _voiceDescriptions = <String, String>{
  'tts:openai_compatible': 'Reads Qiyu’s completed replies aloud through an OpenAI-compatible speech service. Each sentence is checked before playback. Audio stays in memory and is discarded after playback; no audio file is kept.',
  'tts:volc_tts': 'Reads Qiyu’s completed replies through Doubao speech synthesis. Choose HTTP chunks for sentence-by-sentence synthesis or bidirectional WebSocket for continuous synthesis. Enter the Resource-Id as the model. The key stays in local provider.json; audio is discarded after playback.',
  'tts:qwen_tts': 'Reads Qiyu’s completed replies through Qwen speech synthesis. Each sentence is checked before playback. The local host retrieves the audio after the service returns its URL; audio stays in memory and is discarded after playback.',
  'tts:custom': 'Reads Qiyu’s completed replies through a custom speech service. POST to the full URL with {model, input}; audio is read from the selected response format. The key stays in local provider.json, and audio is discarded after playback.',
  'stt:openai_compatible': 'Transcribes speech through an OpenAI-compatible service such as Whisper. The key stays in local provider.json. Recording stays in memory and is discarded after transcription; it is not added to conversations or memories.',
  'stt:volc_seed_asr': 'Transcribes speech through the official Doubao recognition protocol. The key stays in local provider.json. Recording stays in memory and is discarded after transcription; it is not added to conversations or memories.',
  'stt:qwen_asr': 'Transcribes speech through Qwen recognition. The key stays in local provider.json. Recording stays in memory and is discarded after transcription; it is not added to conversations or memories.',
  'stt:custom': 'Transcribes speech through a custom service. POST to the full URL with recording in a multipart form. The key stays in local provider.json. Recording is discarded after transcription and is not added to conversations or memories.',
};

const _voiceExamples = <String, String>{
  'tts:openai_compatible': 'OpenAI-compatible top-level parameters, for example:\n{\n  "response_format": "mp3"\n}\nCompressed formats play one complete sentence at a time.',
  'tts:volc_tts': 'Doubao speech synthesis parameters are deeply merged, for example:\n{\n  "audio_params": { "sample_rate": 16000 },\n  "additions": { "explicit_dialect": "sichuan" }\n}',
  'tts:qwen_tts': 'Qwen speech synthesis parameters are deeply merged into input, for example:\n{\n  "instructions": "Read slowly in a gentle voice"\n}',
  'tts:custom': 'Custom speech synthesis parameters are deeply merged into input, for example:\n{\n  "voice": "custom-voice"\n}',
  'stt:custom': 'Additional multipart form fields for custom transcription, for example:\n{\n  "speaker": "en",\n  "enable_punctuation": true\n}',
};

const _catalogEnglish = <String, String>{
  '官方 API · OpenAI 兼容': 'Official API · OpenAI compatible',
  '模型名称': 'Model name',
  '通用': 'General',
  '方言': 'Dialects',
  'OpenAI 兼容语音合成': 'OpenAI-compatible speech synthesis',
  '豆包语音合成': 'Doubao speech synthesis',
  '千问语音合成': 'Qwen speech synthesis',
  '自定义合成服务': 'Custom speech service',
  'OpenAI 兼容转写': 'OpenAI-compatible transcription',
  '豆包流式语音识别': 'Doubao streaming speech recognition',
  '千问语音识别': 'Qwen speech recognition',
  '自定义转写服务': 'Custom transcription service',
  'HTTP 分块': 'HTTP chunks',
  'WebSocket 双向': 'Bidirectional WebSocket',
  'HTTP 分块：每写好一句合成一句；WebSocket 双向：前几个字一出就开始合成，多轮对话音色语调更连贯。地址栏仍填 HTTP 端点，WebSocket 地址由本机自动派生': 'HTTP chunks synthesize each completed sentence. Bidirectional WebSocket begins after the first few characters and keeps voice and intonation more consistent across turns. Enter the HTTP endpoint; the local host derives the WebSocket URL.',
  '裸音频字节': 'Raw audio bytes',
  'JSON 字段': 'JSON field',
  '逐行 JSON': 'JSON lines',
  'JSON 字段路径': 'JSON field path',
  'SSE 流式': 'SSE stream',
  '留空按默认 Authorization: Bearer 发送': 'Leave blank to send the default Authorization: Bearer header',
  'JSON 字段路径形态生效，点号路径，如 result.text': 'Used for JSON field paths; use dots, e.g. result.text',
  'JSON 字段与逐行 JSON 形态生效，留取缺省 data': 'Used for JSON field and JSON lines; leave blank for the default data field',
  '裸音频字节（且未覆盖成压缩格式）走流式分块合成；逐行 JSON 与 JSON 字段按句子级整段朗读': 'Raw audio bytes stream in chunks unless overridden to a compressed format; JSON lines and JSON fields play complete sentences.',
  '该档不支持自定义高级参数': 'This tier does not support custom advanced parameters',
  '官方 API · Anthropic 兼容': 'Official API · Anthropic compatible',
  '按量付费 · OpenAI 兼容': 'Pay as you go · OpenAI compatible',
  '按量付费 · Anthropic 兼容': 'Pay as you go · Anthropic compatible',
  '开放平台 · OpenAI 兼容': 'Open platform · OpenAI compatible',
  '开放平台 · Anthropic 兼容': 'Open platform · Anthropic compatible',
  'Agent Plan · OpenAI 兼容': 'Agent Plan · OpenAI compatible',
  'Agent Plan · Anthropic 兼容': 'Agent Plan · Anthropic compatible',
  '聚合 API · OpenAI 兼容': 'Aggregated API · OpenAI compatible',
  '本机服务 · Ollama': 'Local service · Ollama',
  '阿里云百炼': 'Alibaba Cloud Bailian',
  '火山方舟': 'Volcengine Ark',
  '智谱 AI': 'Zhipu AI',
  '硅基流动': 'SiliconFlow',
  'Ollama（本机）': 'Ollama (local)',
  '自定义 OpenAI 兼容': 'Custom OpenAI compatible',
  '自定义 Anthropic 兼容': 'Custom Anthropic compatible',
  '标准女声（灿灿）': 'Standard female (Cancan)',
  '高冷御姐': 'Cool female',
  '醇厚男声': 'Deep male',
  '爽快女声': 'Bright female',
  '四川话': 'Sichuan dialect',
  '粤语': 'Cantonese',
  '东北话': 'Northeastern dialect',
  '河南话': 'Henan dialect',
  '陕西话': 'Shaanxi dialect',
  '天津话': 'Tianjin dialect',
  '山东话': 'Shandong dialect',
  '闽南话': 'Southern Min',
  '台湾普通话': 'Taiwan Mandarin',
  'Alloy（中性平衡）': 'Alloy (neutral)',
  'Echo（温和男声）': 'Echo (gentle male)',
  'Fable（英音男声）': 'Fable (British male)',
  'Onyx（深沉男声）': 'Onyx (deep male)',
  'Nova（亲切女声）': 'Nova (warm female)',
  'Shimmer（清亮女声）': 'Shimmer (clear female)',
};
