#!/usr/bin/env python3
"""
Murmur 热词更新 SOP 脚本
-----------------------
用法:
  python3 scripts/update_hotwords.py          # 自动读取 ~/.volc/credentials
  python3 scripts/update_hotwords.py <AK> <SK> # 或手动传入

流程:
  1. 读取 /tmp/murmur_debug.log，提取 ASR 结果
  2. 调用 LLM (gpt-5.2) 分析日志，识别需要添加/修正的热词
  3. 调用火山引擎自学习平台 API 更新 murmur_vocab 词表

AK/SK 存储: ~/.volc/credentials
"""
import warnings
warnings.filterwarnings('ignore')

import sys, os, json, re
sys.path.insert(0, os.path.expanduser('~/Library/Python/3.9/lib/python/site-packages'))

import requests
from collections import OrderedDict
from volcengine.auth.SignerV4 import SignerV4
from volcengine.base.Request import Request

# ── 常量 ────────────────────────────────────────────────────────────────────
LOG_FILE = '/tmp/murmur_debug.log'
CONFIG_FILE = os.path.expanduser(
    '~/Library/Application Support/com.locke.murmur/config.json'
)
VOLC_HOST    = 'open.volcengineapi.com'
VOLC_SERVICE = 'speech_saas_prod'
VOLC_REGION  = 'cn-north-1'
VOLC_VERSION = '2022-08-30'

LLM_ANALYZE_PROMPT = """你是语音识别热词分析专家。

我会给你一段语音识别（ASR）日志，其中包含识别出的文本结果（ASR: 和 LLM: 行）。
请分析这些文本，找出：
1. 专有名词、人名、产品名（如 Armcloud、MCP、天眼查）
2. 经常出现的口语词汇（如 小白、小高 等人名昵称）
3. 可能被错误识别的词（结合上下文推断）

输出格式：仅输出一个 JSON 数组，每个元素是一个热词字符串，不加任何解释。
例：["Armcloud", "MCP", "小白", "天眼查"]

注意：
- 每个词不超过10个汉字或英文单词
- 不要包含普通常用词
- 英文保持原始大小写"""


# ── 读取配置 ────────────────────────────────────────────────────────────────
def load_app_config():
    with open(CONFIG_FILE) as f:
        return json.load(f)


# ── 步骤1: 提取日志中的 ASR 文本 ────────────────────────────────────────────
def extract_asr_texts(log_file=LOG_FILE):
    if not os.path.exists(log_file):
        print(f'[warn] 日志文件不存在: {log_file}')
        return ''
    with open(log_file, encoding='utf-8', errors='replace') as f:
        content = f.read()
    # 提取 ASR(...ms): 和 LLM(...ms): 行
    lines = []
    for line in content.splitlines():
        if re.search(r'\bASR\(\d+ms\):', line) or re.search(r'\bLLM\(\d+ms\):', line):
            lines.append(line.strip())
    return '\n'.join(lines[-500:])  # 最多取最近500行


# ── 步骤2: LLM 分析热词 ──────────────────────────────────────────────────────
def analyze_hotwords_with_llm(asr_text, cfg):
    base_url = cfg.get('llm_base_url', '').rstrip('/')
    api_key  = cfg.get('llm_api_key', '')
    model    = 'gpt-5.2'  # 使用 gpt-5.2，效果好

    if not base_url:
        print('[error] config 中缺少 llm_base_url')
        return []

    print(f'[llm] 调用 {model} 分析热词...')
    resp = requests.post(
        f'{base_url}/v1/chat/completions',
        headers={'Authorization': f'Bearer {api_key}', 'Content-Type': 'application/json'},
        json={
            'model': model,
            'messages': [
                {'role': 'system', 'content': LLM_ANALYZE_PROMPT},
                {'role': 'user',   'content': f'以下是 ASR 日志:\n\n{asr_text}'},
            ],
            'temperature': 0,
        },
        timeout=60,
    )
    resp.raise_for_status()
    content = resp.json()['choices'][0]['message']['content'].strip()
    # 提取 JSON 数组
    match = re.search(r'\[.*?\]', content, re.DOTALL)
    if match:
        return json.loads(match.group())
    return []


# ── Volcengine 鉴权工具 ──────────────────────────────────────────────────────
class VolcCredentials:
    def __init__(self, ak, sk):
        self.ak = ak
        self.sk = sk
        self.service = VOLC_SERVICE
        self.region  = VOLC_REGION
        self.session_token = ''

def volc_json_call(ak, sk, action, body_data):
    r = Request()
    r.method = 'POST'
    r.path   = '/'
    r.host   = VOLC_HOST
    r.headers = OrderedDict([('Content-Type', 'application/json'), ('Host', VOLC_HOST)])
    r.query   = OrderedDict([('Action', action), ('Version', VOLC_VERSION)])
    r.body    = json.dumps(body_data)
    SignerV4.sign(r, VolcCredentials(ak, sk))
    url = f'https://{VOLC_HOST}/?Action={action}&Version={VOLC_VERSION}'
    resp = requests.post(url, headers=dict(r.headers), data=r.body, timeout=30)
    return resp.json()


def volc_multipart_call(ak, sk, action, fields, file_bytes):
    boundary = 'VolcengineBoundaryMurmur'
    parts = []
    for k, v in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}'
            .encode('utf-8')
        )
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="File"; filename="hotwords.txt"\r\n'
        f'Content-Type: text/plain\r\n\r\n'.encode('utf-8') + file_bytes
    )
    body = b'\r\n'.join(parts) + f'\r\n--{boundary}--\r\n'.encode('utf-8')

    r = Request()
    r.method  = 'POST'
    r.path    = '/'
    r.host    = VOLC_HOST
    r.headers = OrderedDict([
        ('Content-Type', f'multipart/form-data; boundary={boundary}'),
        ('Host', VOLC_HOST),
    ])
    r.query = OrderedDict([('Action', action), ('Version', VOLC_VERSION)])
    r.body  = body
    SignerV4.sign(r, VolcCredentials(ak, sk))
    url = f'https://{VOLC_HOST}/?Action={action}&Version={VOLC_VERSION}'
    resp = requests.post(url, headers=dict(r.headers), data=body, timeout=30)
    return resp.json()


# ── 步骤3: 更新词表 ──────────────────────────────────────────────────────────
def update_boosting_table(ak, sk, app_id, table_name, hot_words):
    # 查询现有词表
    result = volc_json_call(ak, sk, 'ListBoostingTable',
                            {'AppID': app_id, 'PageNumber': 1, 'PageSize': 20, 'PreviewSize': 5})
    meta = result.get('ResponseMetadata', {})
    if meta.get('Error'):
        err = meta['Error']
        print(f'[error] ListBoostingTable: {err["Code"]}: {err["Message"]}')
        return False

    tables = result.get('Result', {}).get('BoostingTables', [])
    existing = {t['BoostingTableName']: t for t in tables}
    table_exists = table_name in existing

    if table_exists:
        table_id = existing[table_name]['BoostingTableID']
        action = 'UpdateBoostingTable'
        # UpdateBoostingTable: 只传 AppID + BoostingTableID，不传 Name（否则报 NameDuplicated）
        fields = {'AppID': str(app_id), 'BoostingTableID': table_id}
        print(f'[volc] 更新词表 {table_name} (ID={table_id})...')
    else:
        action = 'CreateBoostingTable'
        fields = {'AppID': str(app_id), 'BoostingTableName': table_name}
        print(f'[volc] 创建词表 {table_name}...')

    # 过滤含特殊字符的词（火山引擎不允许 / 等符号）
    import re
    hot_words = [w for w in hot_words if not re.search(r"[/\\|<>']", w)]
    file_bytes = '\n'.join(hot_words).encode('utf-8')
    result = volc_multipart_call(ak, sk, action, fields, file_bytes)
    meta = result.get('ResponseMetadata', {})
    if meta.get('Error'):
        err = meta['Error']
        print(f'[error] {action}: {err["Code"]}: {err["Message"]}')
        return False

    res = result.get('Result', {})
    print(f'[ok] 词表更新成功: {res.get("BoostingTableName")}, 词数={res.get("WordCount")}')
    return True


# ── 主流程 ───────────────────────────────────────────────────────────────────
def load_credentials():
    """从 ~/.volc/credentials [hotwords] 段读取 AK/SK"""
    cred_file = os.path.expanduser('~/.volc/credentials')
    if not os.path.exists(cred_file):
        return None, None
    import configparser
    conf = configparser.ConfigParser()
    conf.read(cred_file)
    ak = conf.get('hotwords', 'access_key_id', fallback=None)
    sk = conf.get('hotwords', 'secret_access_key', fallback=None)
    return ak, sk


def main():
    if len(sys.argv) >= 3:
        ak, sk = sys.argv[1], sys.argv[2]
    else:
        ak, sk = load_credentials()
        if not ak or not sk:
            print('未找到 AK/SK，请提供参数或在 ~/.volc/credentials 中配置')
            print(__doc__)
            sys.exit(1)
        print(f'[creds] 使用 ~/.volc/credentials')

    # 读取 app 配置
    cfg = load_app_config()
    app_id     = int(cfg['api_app_id'])
    table_name = cfg.get('asr_vocabulary', 'murmur_vocab')

    print(f'AppID={app_id}, 词表={table_name}')

    # 步骤1: 提取日志
    print(f'\n[step 1] 读取日志 {LOG_FILE}...')
    asr_text = extract_asr_texts()
    if not asr_text:
        print('[warn] 日志为空，请确认 murmur 已运行并产生日志')
        sys.exit(1)
    print(f'[ok] 提取到 {len(asr_text.splitlines())} 条 ASR 记录')

    # 步骤2: LLM 分析
    print(f'\n[step 2] LLM 分析热词...')
    hot_words = analyze_hotwords_with_llm(asr_text, cfg)
    if not hot_words:
        print('[warn] LLM 未返回热词，请检查配置')
        sys.exit(1)
    print(f'[ok] LLM 推荐热词: {hot_words}')

    # 人工确认
    print(f'\n即将上传以下热词到 {table_name}:')
    for w in hot_words:
        print(f'  - {w}')
    confirm = input('\n确认更新? [y/N] ').strip().lower()
    if confirm != 'y':
        print('已取消')
        sys.exit(0)

    # 步骤3: 更新词表
    print(f'\n[step 3] 更新火山引擎词表...')
    update_boosting_table(ak, sk, app_id, table_name, hot_words)


if __name__ == '__main__':
    main()
