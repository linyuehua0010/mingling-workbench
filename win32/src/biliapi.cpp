// bili-whale 配置读写实现。见 biliapi.h 的说明：
// 整份读、只改列出来的键、整份写回；保存前备份，写完校验，不过就回滚。
#include "biliapi.h"

#include <cmath>
#include <cstdlib>
#include <cwctype>

#include "core.h"
#include "version.h"

namespace {

// 文件名里能用的时间戳：20261106-231500
std::wstring SafeStamp() {
    std::wstring s = NowStamp();
    s = ReplaceAll(s, L"-", L"");
    s = ReplaceAll(s, L":", L"");
    s = ReplaceAll(s, L" ", L"-");
    return s;
}


std::vector<std::wstring> SplitList(const std::wstring& text) {
    std::vector<std::wstring> out;
    std::wstring cur;
    for (wchar_t c : text) {
        if (c == L'、' || c == L',' || c == L'，' || c == L';' || c == L'；' || c == L'\n' || c == L'\r') {
            std::wstring t = Trim(cur);
            if (!t.empty()) out.push_back(t);
            cur.clear();
        } else {
            cur += c;
        }
    }
    std::wstring t = Trim(cur);
    if (!t.empty()) out.push_back(t);
    return out;
}

std::wstring JoinList(const her::J& j) {
    std::wstring out;
    if (j.t != her::J::ARR) return out;
    for (const her::J& v : j.a) {
        if (v.t != her::J::STR) continue;
        if (!out.empty()) out += L"、";
        out += v.s;
    }
    return out;
}

bool IsSettingsField(const std::wstring& dot) { return !dot.empty() && dot[0] == L'#'; }

}  // namespace

const std::vector<BiliCfgField>& BiliCfgFields() {
    // 字段名逐个对着 sidecar\bili-whale.config.template.json 抄的，没有臆造。
    static const std::vector<BiliCfgField> kFields = {
        // 工作台侧（settings.json）：CLI 参数，不在 bili-whale 的配置文件里
        {L"#bili_grid", L"九宫格", L"看片时抽帧的网格，例如 3x3、4x4（settings.json 的 bili_grid）", 0},
        {L"#bili_timeout_sec", L"看片超时", L"一次 debrief 最多等多久，秒（settings.json 的 bili_timeout_sec）", 1},

        // 选题偏好
        {L"preferences.like", L"爱看什么", L"feed 选题时会往这些方向靠，顿号分隔", 3},
        {L"preferences.dislike", L"不想看什么", L"标题里带这些的会被筛掉，顿号分隔", 3},
        {L"preferences.keywords", L"额外关键词", L"可选，顿号分隔", 3},

        // 风控
        {L"risk.minGapMs", L"动作最小间隔", L"毫秒。两个动作之间至少停这么久", 1},
        {L"risk.readHourly", L"每小时读上限", L"读（刷推荐、看视频）每小时最多几次", 1},
        {L"risk.readDaily", L"每天读上限", L"读的每日上限", 1},
        {L"risk.writeHourly", L"每小时写上限", L"写（评论、点赞）每小时最多几次", 1},
        {L"risk.writeDaily", L"每天写上限", L"写的每日上限", 1},
        {L"risk.writeGapSec", L"写间隔", L"秒。两次写之间至少停这么久", 1},
        {L"risk.dmGapSec", L"私信间隔", L"秒。两条私信之间至少停这么久", 1},

        // 配额
        {L"quota.shareDaily", L"每天分享", L"一天最多分享几条", 1},

        // 作息
        {L"night.skipChance", L"跳过一次的概率", L"0–1 的小数，越大越不规律", 1},
        {L"night.minGapMin", L"清醒最小间隔", L"分钟。半夜醒来两次之间至少隔多久", 1},
        {L"night.maxVideos", L"一次最多看", L"每次醒来最多看几个视频", 1},
        {L"night.maxWakesPerDay", L"每天最多醒", L"一天最多醒几次", 1},
        {L"night.windows", L"作息时段", L"结构比较复杂，看下面这行摘要，改就编辑配置文件", 4},

        // 日记
        {L"diary.enabled", L"写日记", L"关掉就完全不写 whale-diary.md", 2},
        {L"diary.push", L"日记推送", L"写完要不要推给你", 2},

        // 分享
        {L"share.enabled", L"自动分享", L"她刷到好玩的会不会主动发给你", 2},
        {L"share.minScore", L"分享门槛", L"分数低于这个就不发", 1},
        {L"share.silentAfterDays", L"沉默几天后", L"你几天没回，她就少发一点", 1},
        {L"share.aiCommentGuard", L"AI 评论克制", L"开着就不会每条都点评", 2},

        // 听
        {L"listen.comment", L"听评论区", L"要不要读评论", 2},
        {L"listen.commentIntervalSec", L"评论检查间隔", L"秒。多久去评论区看一眼", 1},
    };
    return kFields;
}

std::wstring BiliCfgPath() {
    WhaleEnv we = FindWhale();
    if (!we.config.empty()) return we.config;
    return JoinPath(StateDir(), L"bili-whale.config.json");
}

bool BiliCfgLoad(her::J& root, std::wstring* err) {
    const std::wstring path = BiliCfgPath();
    if (!FileExists(path)) {
        // 跟 FindWhale 一样：没有就从 sidecar 的模板拷一份，别让用户面对空文件
        WhaleEnv we = FindWhale();
        std::wstring tpl = JoinPath(we.pkgDir, L"bili-whale.config.template.json");
        if (FileExists(tpl) && !we.pkgDir.empty()) {
            std::wstring dir = ParentDir(path);
            if (!dir.empty() && !DirExists(dir)) CreateDirectoryW(dir.c_str(), nullptr);
            CopyFileW(tpl.c_str(), path.c_str(), FALSE);
        }
    }
    if (!FileExists(path)) {
        root = her::JObj();
        if (err) err->clear();
        return true;
    }
    bool ok = false;
    root = her::J::Parse(ReadTextFile(path, 1 << 20), &ok);
    if (!ok || !root.Obj()) {
        root = her::JObj();
        if (err) *err = L"配置文件读不出来（不是合法 JSON）：" + path;
        return false;
    }
    return true;
}

std::wstring BiliCfgShow(const her::J& root, const BiliCfgField& f) {
    if (IsSettingsField(f.dot)) {
        if (f.dot == L"#bili_grid") {
            return BiliGridSetting();
        }
        if (f.dot == L"#bili_timeout_sec") return Num(BiliTimeoutSec());
        return L"";
    }
    const her::J* v = root.Path(f.dot);
    if (!v) return L"";
    if (f.kind == 4) {
        if (v->t != her::J::ARR) return L"（没有配）";
        std::wstring out;
        for (const her::J& w : v->a) {
            if (w.t != her::J::OBJ) continue;
            std::wstring s0 = w.Str(L"start"), s1 = w.Str(L"end");
            long long wakes = w.Int(L"wakes");
            if (s0.empty() && s1.empty()) continue;
            if (!out.empty()) out += L"    ·    ";
            out += s0 + L"–" + s1 + L" ×" + Num(wakes);
        }
        return out.empty() ? std::wstring(L"（没有配）") : out;
    }
    switch (v->t) {
        case her::J::BOOL:
            return v->b ? L"开" : L"关";
        case her::J::NUM:
            return v->NumText();
        case her::J::STR:
            return v->s;
        case her::J::ARR:
            return JoinList(*v);
        default:
            return L"";
    }
}

bool BiliCfgApply(her::J& root, const BiliCfgField& f, const std::wstring& text, std::wstring* err) {
    if (f.kind == 4) {
        if (err) *err = L"这一项要直接改配置文件";
        return false;
    }
    const std::wstring t = Trim(text);

    if (IsSettingsField(f.dot)) {
        if (f.dot == L"#bili_grid") {
            if (t.empty()) {
                SettingSet(L"bili_grid", L"");
                return true;
            }
            // 只认 NxM 这种形状，别把奇怪的字符串塞进命令行
            bool shape = t.size() >= 3;
            size_t x = t.find_first_of(L"xX×");
            if (x == std::wstring::npos || x == 0 || x + 1 >= t.size()) shape = false;
            if (shape) {
                for (size_t i = 0; i < t.size(); i++) {
                    if (i == x) continue;
                    if (!iswdigit(t[i])) shape = false;
                }
            }
            if (!shape) {
                if (err) *err = L"网格要写成 3x3 这样";
                return false;
            }
            SettingSet(L"bili_grid", t);
            return true;
        }
        if (f.dot == L"#bili_timeout_sec") {
            long long sec = _wtoi64(t.c_str());
            if (sec < 30 || sec > 3600) {
                if (err) *err = L"超时写 30–3600 之间的秒数";
                return false;
            }
            // 存成数字而不是字符串：settings.json 是给人看也给人改的
            SettingRawSet(L"bili_timeout_sec", Num(sec));
            return true;
        }
        return false;
    }

    if (f.kind == 2) {
        // 布尔：界面给的是「开 / 关」，也接受 1/0/true/false
        bool on = (t == L"开" || t == L"1" || t == L"true" || t == L"on" || t == L"是");
        if (t != L"开" && t != L"关" && t != L"1" && t != L"0" && t != L"true" && t != L"false" &&
            t != L"on" && t != L"off" && t != L"是" && t != L"否") {
            if (err) *err = L"这一项只能填「开」或「关」";
            return false;
        }
        root.PathSet(f.dot, her::JBool(on));
        return true;
    }
    if (f.kind == 1) {
        if (t.empty()) {
            if (err) *err = L"不能为空";
            return false;
        }
        wchar_t* end = nullptr;
        double v = wcstod(t.c_str(), &end);
        if (!end || *end != 0 || !std::isfinite(v)) {
            if (err) *err = L"要填数字";
            return false;
        }
        root.PathSet(f.dot, her::JNum(v));
        return true;
    }
    if (f.kind == 3) {
        her::J arr = her::JArr();
        for (const std::wstring& s : SplitList(t)) arr.Push(her::JStr(s));
        root.PathSet(f.dot, arr);
        return true;
    }
    root.PathSet(f.dot, her::JStr(t));
    return true;
}

bool BiliCfgSave(const her::J& root, std::wstring* err) {
    const std::wstring path = BiliCfgPath();
    std::wstring dir = ParentDir(path);
    if (!dir.empty() && !DirExists(dir)) CreateDirectoryW(dir.c_str(), nullptr);

    // 同一秒里存两次不会互相覆盖：撞名就往后加 -2、-3
    std::wstring bak = path + L".bak-" + SafeStamp();
    for (int n = 2; FileExists(bak) && n < 50; n++) bak = path + L".bak-" + SafeStamp() + L"-" + Num(n);
    const bool had = FileExists(path);
    if (had && !CopyFileW(path.c_str(), bak.c_str(), FALSE)) {
        if (err) *err = L"备份失败，没敢写（" + bak + L"）";
        return false;
    }

    const std::wstring text = root.Dump(2);
    if (!WriteTextFile(path, text)) {
        if (err) *err = L"写不进去：" + path;
        if (had) CopyFileW(bak.c_str(), path.c_str(), FALSE);
        return false;
    }

    // 写完自己再读一遍：文件里出现了不合法的 JSON 就回滚，别把她的配置弄坏
    bool ok = false;
    her::J back = her::J::Parse(ReadTextFile(path, 1 << 20), &ok);
    if (!ok || !back.Obj()) {
        if (had) CopyFileW(bak.c_str(), path.c_str(), FALSE);
        else DeleteFileW(path.c_str());
        if (err) *err = L"写出来的不是合法 JSON，已经回滚到备份";
        return false;
    }
    if (err) err->clear();
    return true;
}

std::wstring BiliGridSetting() {
    std::wstring g = Trim(SettingGet(L"bili_grid"));
    if (g.empty()) return L"3x3";
    return g;
}

int BiliTimeoutSec() {
    long long sec = _wtoi64(Trim(SettingGet(L"bili_timeout_sec")).c_str());
    if (sec < 30 || sec > 3600) return 420;
    return (int)sec;
}
