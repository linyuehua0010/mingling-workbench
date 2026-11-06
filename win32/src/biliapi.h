// bili-whale 配置读写（B 站页的「配置」区）。
//
// 只碰这里列出来的字段：配置文件是上游 bili-whale 的，我们不懂的键必须原样保留，
// 所以整份 JSON 读进来、改几处、再整份写回去，而不是重新生成一份。
//
// 保存前先备份成 <文件>.bak-<时间>；写完重新解析一遍，解析不过就把备份拷回去。
#pragma once

#include <string>
#include <vector>

#include "her/her.h"

// kind: 0 文本  1 数字  2 布尔  3 字符串列表  4 只读（只看不写）
// dot 以 '#' 开头的是工作台自己的 settings.json 键（网格、超时这类 CLI 参数，
// bili-whale 的配置文件里没有这些字段，不往人家的文件里塞）。
struct BiliCfgField {
    std::wstring dot;
    std::wstring label;
    std::wstring hint;
    int kind = 0;
};

const std::vector<BiliCfgField>& BiliCfgFields();

// BILI_WHALE_CONFIG 指向的那份配置（快照版就是 %APPDATA%\MinglingWorkbench\snapshot\bili-whale.config.json）
std::wstring BiliCfgPath();

// 读盘。文件不存在时先尝试从 sidecar 的模板拷一份；连模板都没有就给一个空对象。
bool BiliCfgLoad(her::J& root, std::wstring* err);

// 给界面看的字符串（列表用「、」连起来，布尔给「开 / 关」）
std::wstring BiliCfgShow(const her::J& root, const BiliCfgField& f);

// 把界面上的字符串写进 root（'#' 开头的写 settings.json）
bool BiliCfgApply(her::J& root, const BiliCfgField& f, const std::wstring& text, std::wstring* err);

// 备份 → 写 → 重新解析校验 → 失败回滚。root 里 '#' 的字段不写进这个文件。
bool BiliCfgSave(const her::J& root, std::wstring* err);

// 网格（debrief --grid）与超时（毫秒）跟着 settings.json 走，看片命令读它们
std::wstring BiliGridSetting();
int BiliTimeoutSec();

// ---------------------------------------------------------------- DSH 对话 API
// 这是个外部 HTTP 接口（OpenAI 兼容的 /chat/completions），不是 DSH 运行时：
// 不安装、不启动、不读 ~/.dsh。填好就能用，连不上只影响这一个功能。
struct DshApiCfg {
    bool enabled = false;
    std::wstring base;    // 例如 https://api.deepseek.com/v1
    std::wstring model;   // 例如 deepseek-chat
    std::wstring path;    // 默认 /chat/completions
    int timeoutSec = 60;  // 5–300
    std::wstring key;     // 只存在 <base>\secrets\dsh-api-key.txt，不写 settings.json
};

// 密钥文件：secrets\dsh-api-key.txt（secrets 目录被重定向时跟着走）
std::wstring DshApiKeyPath();

// 配置项落在 settings.json 的 dsh_api_* 里；密钥单独一个文件
DshApiCfg DshApiLoad();
bool DshApiSave(const DshApiCfg& cfg, std::wstring* err);

// base + path 拼成真正要 POST 的地址（界面和测试都用它）
std::wstring DshApiUrl(const DshApiCfg& cfg);

// 问一句。成功回 reply（模型原文），失败回 err（中文，能直接显示）。
// 调用方负责放到工作线程里跑——它会等网络。
bool DshChat(const std::wstring& prompt, const DshApiCfg& cfg, std::wstring* reply, std::wstring* err);
