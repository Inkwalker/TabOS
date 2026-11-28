#include "font_lua.hpp"

#include <algorithm>
#include <limits>
#include <memory>
#include <new>

#include "commands.hpp"
#include "gfx.hpp"

extern "C" {
    #include "lauxlib.h"
    #include "lua.h"
}

namespace gfx {
namespace {

constexpr const char* font_type = "gfx.Font";
char active_font_key;

class LuaFont final : public lgfx::GFXfont {
public:
    explicit LuaFont(uint8_t line_height)
        : GFXfont(nullptr, nullptr, 0, 0, line_height) {}

    void getDefaultMetric(lgfx::FontMetrics* metrics) const override
    {
        *metrics = {0, 0, 0, int16_t(ascent + descent), yAdvance, int16_t(-ascent), ascent};
    }

    std::unique_ptr<lgfx::GFXglyph[]> glyphs;
    std::unique_ptr<lgfx::EncodeRange[]> ranges;
    std::unique_ptr<uint8_t[]> pixels;
    int16_t ascent = 0;
    int16_t descent = 0;
    bool submitted = false;
};

int release_font(lua_State* state)
{
    auto** font = static_cast<LuaFont**>(luaL_checkudata(state, 1, font_type));
    if (*font && (*font)->submitted) {
        DrawCommand command{DrawOp::release_font};
        command.payload.font = *font;
        execute_and_wait(command);
    }
    delete *font;
    *font = nullptr;
    return 0;
}

constexpr int max_row_width = std::numeric_limits<lua_Integer>::digits;
constexpr const char* font_allocation_error = "out of memory creating font";
constexpr lua_Integer invalid_font_integer = std::numeric_limits<lua_Integer>::min();

// Keep the field keys on the stack so both passes can use raw lookups without Lua allocations.
struct GlyphFields {
    int width;
    int advance;
    int x_offset;
    int y_offset;
    int rows;
};

struct IndexedGlyph {
    uint16_t codepoint;
    lgfx::GFXglyph glyph;
};

int push_font_key(lua_State* state, const char* name)
{
    lua_pushstring(state, name);
    return lua_gettop(state);
}

lua_Integer font_integer(lua_State* state, int table, int key, lua_Integer missing = invalid_font_integer)
{
    lua_pushvalue(state, key);
    lua_rawget(state, table);
    const auto value = lua_isinteger(state, -1) ? lua_tointeger(state, -1)
                     : lua_isnil(state, -1) ? missing : invalid_font_integer;
    lua_pop(state, 1);
    return value;
}

bool glyph_codepoint(lua_State* state, int index, uint16_t& codepoint)
{
    if (lua_type(state, index) != LUA_TSTRING) return false;
    size_t length;
    const auto* bytes = reinterpret_cast<const uint8_t*>(lua_tolstring(state, index, &length));
    if (length < 1 || length > 3) return false;

    constexpr uint8_t prefix[] = {0, 0xc0, 0xe0};
    constexpr uint8_t masks[] = {0x7f, 0x1f, 0x0f};
    constexpr uint16_t minimum[] = {0, 0x80, 0x800};
    const uint8_t mask = masks[length - 1];
    if ((bytes[0] & ~mask) != prefix[length - 1]) return false;
    unsigned value = bytes[0] & mask;
    for (size_t i = 1; i < length; ++i) {
        if ((bytes[i] & 0xc0) != 0x80) return false;
        value = (value << 6) | (bytes[i] & 0x3f);
    }
    if (value < minimum[length - 1] || (value >= 0xd800 && value <= 0xdfff)) return false;
    codepoint = static_cast<uint16_t>(value);
    return true;
}

// On success, leave the rows table on top of the stack.
const char* read_font_glyph(lua_State* state, const GlyphFields& fields, IndexedGlyph& entry)
{
    if (!glyph_codepoint(state, -2, entry.codepoint)) return "glyph key must be one UTF-8 character in the BMP";
    if (!lua_istable(state, -1)) return "expected a glyph table";
    const int glyph_table = lua_gettop(state);
    lua_pushvalue(state, fields.rows);
    if (lua_rawget(state, glyph_table) != LUA_TTABLE) return "glyph rows must be a table";
    const size_t height = lua_rawlen(state, -1);
    if (height > UINT8_MAX) return "glyph has more than 255 rows";
    const auto width = font_integer(state, glyph_table, fields.width, 0);
    if (height == 0 ? width != 0 : width < 1 || width > max_row_width) {
        return "glyph width must fit a nonnegative Lua integer and be zero only for empty rows";
    }
    const auto advance = font_integer(state, glyph_table, fields.advance);
    if (advance < 0 || advance > UINT8_MAX) return "glyph advance must be an integer from 0 to 255";
    const auto x_offset = font_integer(state, glyph_table, fields.x_offset, 0);
    const auto y_offset = font_integer(state, glyph_table, fields.y_offset, -static_cast<int>(height));
    if (x_offset < INT8_MIN || x_offset > INT8_MAX || y_offset < INT8_MIN || y_offset > INT8_MAX) {
        return "glyph offsets must be integers from -128 to 127";
    }
    entry.glyph = {0, uint8_t(width), uint8_t(height), uint8_t(advance), int8_t(x_offset), int8_t(y_offset)};
    return nullptr;
}

const char* pack_font_rows(lua_State* state, const lgfx::GFXglyph& glyph, uint8_t* bitmap)
{
    const lua_Unsigned row_limit = lua_Unsigned{1} << glyph.width;
    const int rows = lua_gettop(state);
    size_t count = 0;
    lua_pushnil(state);
    while (lua_next(state, rows)) {
        const auto index = lua_tointeger(state, -2);
        if (!lua_isinteger(state, -2) || index < 1 || index > glyph.height) {
            return "glyph rows must be a dense array";
        }
        const auto row = lua_tointeger(state, -1);
        if (!lua_isinteger(state, -1) || row < 0 || lua_Unsigned(row) >= row_limit) {
            return "glyph row must be a nonnegative integer that fits its width";
        }
        size_t bit = (index - 1) * glyph.width;
        for (lua_Unsigned mask = row_limit >> 1; mask != 0; mask >>= 1, ++bit) {
            if (lua_Unsigned(row) & mask) bitmap[bit / 8] |= 0x80 >> (bit % 8);
        }
        ++count;
        lua_pop(state, 1);
    }
    return count == glyph.height ? nullptr : "glyph rows must be a dense array";
}

const char* build_font(lua_State* state, LuaFont& font, int glyph_table, const GlyphFields& fields)
{
    size_t count = 0;
    size_t bitmap_size = 0;
    lua_pushnil(state);
    while (lua_next(state, glyph_table)) {
        IndexedGlyph entry;
        if (const auto* error = read_font_glyph(state, fields, entry)) return error;
        bitmap_size += (entry.glyph.width * entry.glyph.height + 7) / 8 + 1;
        ++count;
        lua_pop(state, 2);
    }
    if (count == 0) return "font must have at least one glyph";

    const std::unique_ptr<IndexedGlyph[]> entries(new (std::nothrow) IndexedGlyph[count]);
    font.pixels.reset(new (std::nothrow) uint8_t[bitmap_size]{});
    if (!entries || !font.pixels) return font_allocation_error;

    size_t offset = 0;
    size_t index = 0;
    lua_pushnil(state);
    while (lua_next(state, glyph_table)) {
        auto& entry = entries[index++];
        if (const auto* error = read_font_glyph(state, fields, entry)) return error;
        auto& glyph = entry.glyph;
        glyph.bitmapOffset = offset;
        if (const auto* error = pack_font_rows(state, glyph, font.pixels.get() + offset)) return error;
        offset += (glyph.width * glyph.height + 7) / 8;
        // M5GFX scans ahead for a change of bit value. This byte ends either run.
        font.pixels[offset++] = 0x80;
        if (glyph.height != 0) {
            font.ascent = std::max<int>(font.ascent, -glyph.yOffset);
            font.descent = std::max<int>(font.descent, glyph.height + glyph.yOffset);
        }
        lua_pop(state, 2);
    }

    std::sort(entries.get(), entries.get() + count, [](const IndexedGlyph& a, const IndexedGlyph& b) {
        return a.codepoint < b.codepoint;
    });
    size_t range_count = 1;
    for (size_t i = 1; i < count; ++i) {
        if (entries[i].codepoint != entries[i - 1].codepoint + 1) ++range_count;
    }
    font.glyphs.reset(new (std::nothrow) lgfx::GFXglyph[count]);
    if (range_count > 1) font.ranges.reset(new (std::nothrow) lgfx::EncodeRange[range_count]);
    if (!font.glyphs || (range_count > 1 && !font.ranges)) return font_allocation_error;

    font.first = entries[0].codepoint;
    font.last = entries[count - 1].codepoint;
    font.glyph = font.glyphs.get();
    font.bitmap = font.pixels.get();
    font.range = font.ranges.get();
    for (size_t i = 0; i < count; ++i) {
        font.glyph[i] = entries[i].glyph;
        if (!font.range) continue;
        const uint16_t codepoint = entries[i].codepoint;
        if (i == 0 || codepoint != entries[i - 1].codepoint + 1) {
            font.range[font.range_num++] = {codepoint, codepoint, uint16_t(i)};
        } else {
            font.range[font.range_num - 1].end = codepoint;
        }
    }
    return nullptr;
}

int font_error(lua_State* state, const char* error)
{
    lua_pushnil(state);
    lua_pushstring(state, error);
    return 2;
}

} // namespace

int create_font(lua_State* state)
{
    if (!lua_istable(state, 1)) return font_error(state, "expected a font table");
    const auto line_height = font_integer(state, 1, push_font_key(state, "line_height"));
    if (line_height < 1 || line_height > UINT8_MAX) {
        return font_error(state, "line_height must be an integer from 1 to 255");
    }
    lua_pushliteral(state, "glyphs");
    if (lua_rawget(state, 1) != LUA_TTABLE) return font_error(state, "font glyphs must be a table");
    const int glyph_table = lua_gettop(state);

    auto** slot = static_cast<LuaFont**>(lua_newuserdatauv(state, sizeof(LuaFont*), 0));
    const int userdata = lua_gettop(state);
    *slot = nullptr;
    luaL_setmetatable(state, font_type);
    const GlyphFields fields{push_font_key(state, "width"), push_font_key(state, "advance"),
                             push_font_key(state, "x_offset"), push_font_key(state, "y_offset"),
                             push_font_key(state, "rows")};
    *slot = new (std::nothrow) LuaFont(line_height);
    if (!*slot) return font_error(state, font_allocation_error);
    if (const auto* error = build_font(state, **slot, glyph_table, fields)) {
        delete *slot;
        *slot = nullptr;
        return font_error(state, error);
    }
    lua_settop(state, userdata);
    return 1;
}

int set_font(lua_State* state)
{
    LuaFont* font = nullptr;
    if (!lua_isnoneornil(state, 1)) {
        font = *static_cast<LuaFont**>(luaL_checkudata(state, 1, font_type));
    }
    if (!active_canvas()) return luaL_error(state, "gfx has no active canvas");

    // Keep the selected font alive even if the script drops its copy.
    if (font) lua_pushvalue(state, 1);
    else lua_pushnil(state);
    lua_rawsetp(state, LUA_REGISTRYINDEX, &active_font_key);
    if (font) font->submitted = true;

    DrawCommand command{DrawOp::set_font};
    command.payload.font = font;
    enqueue(command);
    return 0;
}

void register_font_type(lua_State* state)
{
    if (luaL_newmetatable(state, font_type)) {
        lua_pushcfunction(state, release_font);
        lua_setfield(state, -2, "__gc");
        lua_pushstring(state, font_type);
        lua_setfield(state, -2, "__metatable");
    }
    lua_pop(state, 1);
}

} // namespace gfx
