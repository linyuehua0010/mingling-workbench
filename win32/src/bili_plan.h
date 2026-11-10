#pragma once
#include "biliapi.h"
#include <cmath>
#include <set>

// The model may select only known candidates; it never supplies commands or URLs.
namespace bili {
inline int Limit(const her::J& config, const wchar_t* path, int fallback, int hi) {
    const auto* v = config.Path(path);
    return v && v->t == her::J::NUM && std::isfinite(v->num)
        ? (int)std::max(0.0, std::min((double)hi, v->num)) : fallback;
}
inline int Minute(const std::wstring& s) {
    auto colon = s.find(L':');
    if (colon == std::wstring::npos || colon == 0 || s.size() - colon != 3 || colon > 2) return -1;
    for (size_t i = 0; i < s.size(); ++i) if (i != colon && (s[i] < L'0' || s[i] > L'9')) return -1;
    int h = _wtoi(s.substr(0, colon).c_str()), m = _wtoi(s.substr(colon + 1).c_str());
    return h <= 24 && m < 60 && (h < 24 || m == 0) ? h * 60 + m : -1;
}
inline bool InWindow(const her::J& config, int minute) {
    const auto* windows = config.Path(L"night.windows");
    if (!windows || !windows->Arr()) return minute >= 20 * 60;
    for (const auto& w : windows->a) {
        int start = Minute(w.Str(L"start")), end = Minute(w.Str(L"end"));
        if (start < 0 || start >= 1440 || end < 0 || start == end) continue;
        if (end > start ? minute >= start && minute < end : minute >= start || minute < end) return true;
    }
    return false;
}
inline bool ParsePlan(const std::wstring& reply, const std::vector<FeedItem>& candidates,
                      long long now, int maxVideos, her::J* result, std::wstring* error, int gapMinutes = 10) {
    std::wstring raw = Trim(reply);
    if (StartsWith(raw, L"```")) {
        auto begin = raw.find(L'\n'), end = raw.rfind(L"```");
        if (begin != std::wstring::npos && end > begin) raw = raw.substr(begin + 1, end - begin - 1);
    }
    bool ok = false;
    auto parsed = her::J::Parse(raw, &ok);
    const auto* tasks = parsed.Get(L"tasks");
    if (!ok || !parsed.Obj() || !tasks || !tasks->Arr() || tasks->a.size() > (size_t)maxVideos) {
        if (error) *error = L"API 没有返回有效任务计划，未安排观看";
        return false;
    }
    her::J out = her::JObj(), queue = her::JArr();
    std::set<std::wstring> used;
    long long last = now;
    for (const auto& task : tasks->a) {
        std::wstring bv = task.Str(L"bv");
        auto it = std::find_if(candidates.begin(), candidates.end(), [&](const FeedItem& f) { return f.bv == bv; });
        const auto* delay = task.Get(L"delay_minutes");
        if (it == candidates.end() || !used.insert(bv).second || !delay || delay->t != her::J::NUM ||
            !std::isfinite(delay->num) || delay->num < 0 || delay->num > 120 || std::floor(delay->num) != delay->num) {
            if (error) *error = L"API 计划包含未知视频、重复任务或无效时间，未安排观看";
            return false;
        }
        her::J row = her::JObj();
        long long due = std::max(queue.a.empty() ? now : last + gapMinutes * 60LL, now + (long long)delay->num * 60); last = due;
        row.Set(L"bv", bv); row.Set(L"title", it->title); row.Set(L"due", due);
        row.Set(L"reason", task.Str(L"reason").substr(0, 200)); row.Set(L"status", L"pending"); queue.Push(row);
    }
    out.Set(L"tasks", queue);
    out.Set(L"nextRefresh", now + std::max(15, Limit(parsed, L"next_refresh_minutes", 60, 1440)) * 60LL);
    *result = out;
    return true;
}
}
