---
name: analyze-images-with-qwen-flash
description: Analyze local images, screenshots, diagrams, charts, interfaces, photos, and image URLs with the multimodal Qwen3.5-Flash model through the DashScope OpenAI-compatible API, without MCP or third-party Python packages. Use when the active model cannot inspect image pixels and the task requires fast visual description, UI inspection, chart or diagram reasoning, object identification, OCR-assisted understanding, or comparison across images.
---

# Analyze Images with Qwen3.5-Flash

Use the bundled script as a fast general-purpose vision fallback. Send only the images and question required for the current task, then treat the returned text as external visual evidence.

## Prerequisite

Read the API key only from `QWEN35_FLASH_API_KEY`.

Never place an API key in a prompt, command argument, repository file, log, or response. If the variable is missing, tell the user to configure `QWEN35_FLASH_API_KEY` and restart the agent application before retrying.

## Workflow

1. Confirm that the answer depends on image pixels. Do not invoke the vision model merely because an image is mentioned.
2. Resolve every target to an accessible local image path or an `http://`/`https://` URL. If neither is available, ask the user to attach the image or provide its path or URL.
3. Turn the user's request into a focused visual question. Preserve requested fields, ordering, language, coordinates, uncertainty markers, and output format.
4. On Windows, invoke the launcher using its absolute path:

   ```text
   & "<skill-directory>\scripts\analyze_image.cmd" --image "C:\path\screen.png" --prompt "说明界面中的报错、对应组件和可见状态；不要猜测不可见信息。"
   ```

   Repeat `--image` for comparisons or multi-image questions:

   ```text
   & "<skill-directory>\scripts\analyze_image.cmd" --image "before.png" --image "after.png" --prompt "按输入顺序比较两张图，只列出可见差异。"
   ```

   Replace `<skill-directory>` with the directory containing this `SKILL.md`. The launcher discovers and validates Python 3 and rejects Windows Store placeholders. On non-Windows systems, locate a real Python 3 interpreter and run `scripts/analyze_image.py` directly.
5. Read stdout as the visual result. Preserve uncertainty and do not claim details absent from the result.
6. If a required detail is missing, make at most one focused retry with a narrower prompt. Do not loop on API errors.

## Failure handling

- For a missing key, explain how to set `QWEN35_FLASH_API_KEY`; never ask the user to paste it into chat.
- For HTTP 401 or 403, report that the API key, region, or service authorization must be checked.
- For HTTP 429, report the rate or quota limit and stop.
- For an unreadable path or unsupported image type, correct the input or ask for a supported image.
- For blurred, occluded, or ambiguous visual evidence, report uncertainty instead of inventing content.

The script calls model `qwen3.5-flash` at `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`. It disables deep thinking by default to prioritize response speed. Local images are sent as MIME-correct Base64 data URLs. The implementation uses only the Python standard library and has no MCP dependency.
