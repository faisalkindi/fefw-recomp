// SPDX-License-Identifier: GPL-3.0-or-later
// Wrapped menu text that may be right to left (include/nxrt/menu_i18n.h). ImGui breaks a line from the start of its string, which
// for text in display order is the end of the sentence, so right-to-left text is broken here instead: from its reading start (the
// right end), each line set against the right edge.
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

#include <imgui.h>

#include "nxrt/menu_i18n.h"
#include "nxrt/rtl_text.h"

namespace nxrt::gfx {

namespace {

std::string vformat(const char* fmt, va_list ap) {
    va_list again;
    va_copy(again, ap);
    const int n = std::vsnprintf(nullptr, 0, fmt, again);
    va_end(again);
    if (n <= 0) return {};
    std::string out(static_cast<size_t>(n) + 1, '\0');
    std::vsnprintf(out.data(), out.size(), fmt, ap);
    out.resize(static_cast<size_t>(n));
    return out;
}

// One display-order line, right to left: its words in reading order are the display words from the right. Words with no
// right-to-left letter next to each other are one left-to-right phrase and stay together.
void draw_rtl_line(const std::u32string& line, float width) {
    std::vector<std::u32string> units;
    bool last_ltr = false;
    size_t a = 0;
    while (a <= line.size()) {
        size_t b = line.find(U' ', a);
        if (b == std::u32string::npos) b = line.size();
        const std::u32string word = line.substr(a, b - a);
        const bool ltr = !rtl::has_rtl(word);
        if (!word.empty()) {
            if (ltr && last_ltr && !units.empty()) units.back() += U" " + word;
            else units.push_back(word);
            last_ltr = ltr;
        }
        a = b + 1;
    }
    // a left-to-right phrase wider than the line is cut between its words into pieces that fit; the units are read from the end,
    // so the pieces go in last-first and the phrase's first words come on the upper line
    auto wide = [](const std::u32string& s) { return ImGui::CalcTextSize(rtl::u32_to_utf8(s).c_str()).x; };
    std::vector<std::u32string> fitted;
    for (const std::u32string& u : units) {
        if (rtl::has_rtl(u) || wide(u) <= width) {
            fitted.push_back(u);
            continue;
        }
        std::vector<std::u32string> pieces;
        std::u32string piece;
        size_t p = 0;
        while (p <= u.size()) {
            size_t q = u.find(U' ', p);
            if (q == std::u32string::npos) q = u.size();
            const std::u32string word = u.substr(p, q - p);
            const std::u32string cand = piece.empty() ? word : piece + U" " + word;
            if (!piece.empty() && wide(cand) > width) {
                pieces.push_back(piece);
                piece = word;
            } else {
                piece = cand;
            }
            p = q + 1;
        }
        if (!piece.empty()) pieces.push_back(piece);
        fitted.insert(fitted.end(), pieces.rbegin(), pieces.rend());
    }
    units.swap(fitted);
    const float x0 = ImGui::GetCursorPosX();
    auto emit = [&](const std::u32string& l) {
        const std::string s = rtl::u32_to_utf8(l);
        const float w = ImGui::CalcTextSize(s.c_str()).x;
        ImGui::SetCursorPosX(x0 + std::max(0.f, width - w));
        ImGui::TextUnformatted(s.c_str());
    };
    std::u32string cur;
    for (size_t i = units.size(); i-- > 0;) {
        const std::u32string cand = cur.empty() ? units[i] : units[i] + U" " + cur;
        if (!cur.empty() && ImGui::CalcTextSize(rtl::u32_to_utf8(cand).c_str()).x > width) {
            emit(cur);
            cur = units[i];
        } else {
            cur = cand;
        }
    }
    emit(cur);
}

void wrapped(bool disabled, const char* fmt, va_list ap) {
    const std::string text = vformat(fmt, ap);
    const std::u32string u = rtl::utf8_to_u32(text);
    if (!rtl::has_rtl(u)) {
        if (disabled) ImGui::TextDisabled("%s", text.c_str());
        else ImGui::TextWrapped("%s", text.c_str());
        return;
    }
    if (disabled) ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetStyle().Colors[ImGuiCol_TextDisabled]);
    const float width = ImGui::GetContentRegionAvail().x;
    size_t a = 0;
    while (true) {
        const size_t b = u.find(U'\n', a);
        draw_rtl_line(u.substr(a, b == std::u32string::npos ? std::u32string::npos : b - a), width);
        if (b == std::u32string::npos) break;
        a = b + 1;
    }
    if (disabled) ImGui::PopStyleColor();
}

}  // namespace

void text_wrapped(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    wrapped(false, fmt, ap);
    va_end(ap);
}

void text_wrapped_disabled(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    wrapped(true, fmt, ap);
    va_end(ap);
}

}  // namespace nxrt::gfx
