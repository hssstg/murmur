#!/usr/bin/env python3
"""直接调 LLM 测试热词提取，数据来自 murmur 本地文件"""
import json, urllib.request, datetime, os

APP_SUPPORT = os.path.expanduser("~/Library/Application Support/com.locke.murmur")

with open(f"{APP_SUPPORT}/config.json") as f:
    cfg = json.load(f)

with open(f"{APP_SUPPORT}/history.json") as f:
    history = json.load(f)

with open(f"{APP_SUPPORT}/hotwords.json") as f:
    hotwords = json.load(f)  # list of strings

# 最近 7 天
cutoff = (datetime.datetime.now() - datetime.timedelta(days=7)).isoformat()
recent = [e for e in history if e.get("date", "") >= cutoff]
recent_texts = [e.get("edited") or e.get("text", "") for e in recent]

# 修正记录
corrections = [
    f"原文：{e['text']}\n修正：{e['edited']}"
    for e in history if e.get("edited")
]

print(f"最近7天记录: {len(recent_texts)} 条")
print(f"修正记录: {len(corrections)} 条")
print(f"现有热词: {len(hotwords)} 个")
print()

existing_line = "、".join(hotwords) if hotwords else "（无）"
recent_line = "\n".join(f"{i+1}. {t}" for i, t in enumerate(recent_texts[:100])) or "（无）"
correction_line = "\n\n".join(corrections[:80]) or "（无）"

user_content = f"""【当前热词库】
{existing_line}

【最近7天识别记录】
{recent_line}

【修正记录】
{correction_line}"""

system_prompt = """你是语音识别热词分析专家。

我会提供：
1. 当前热词库（已有词，不要重复推荐）
2. 最近7天的语音识别记录（用户说的话，用于发现高频专业词汇）
3. 用户对语音识别结果的修正记录（原始识别 → 用户修正，重点关注被错认的词）

你的任务：综合识别记录和修正记录，提取适合加入热词库的词条。

重点关注：
- 专有名词、品牌名、人名（如 Armcloud、MCP、天眼查）
- 技术术语、行业词汇
- 修正记录中出现的被错认词

输出格式：仅输出一个 JSON 数组，每个元素是一个热词字符串，不加任何解释。
例：["Armcloud", "MCP", "天眼查"]

限制：
- 不要推荐已在热词库中的词
- 每个词不超过 10 个汉字或英文单词
- 不要推荐普通常用词、语气词、代词
- 若没有可提取的词，返回空数组 []"""

base_url = cfg["llm_base_url"].rstrip("/")
url = f"{base_url}/v1/chat/completions"
payload = json.dumps({
    "model": cfg["llm_model"],
    "messages": [
        {"role": "system", "content": system_prompt},
        {"role": "user",   "content": user_content},
    ],
    "temperature": 0,
}).encode()

req = urllib.request.Request(url, data=payload, headers={
    "Authorization": f"Bearer {cfg['llm_api_key']}",
    "Content-Type": "application/json",
})

print("=== 发送的 user_content ===")
print(user_content[:2000])
print()
print("=== LLM 响应 ===")
with urllib.request.urlopen(req, timeout=60) as resp:
    result = json.load(resp)
    content = result["choices"][0]["message"]["content"]
    print(content)
