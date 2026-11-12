#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

extern "C" {
#include "lauxlib.h"
}

namespace tabos::fs {
namespace {

constexpr unsigned max_depth = 8;

bool digit(int c) { return c >= '0' && c <= '9'; }
bool letter(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
bool space(int c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'; }
bool keyword(std::string_view name)
{
    constexpr std::string_view words[] = {"and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"};
    return std::find(std::begin(words), std::end(words), name) != std::end(words);
}
int hex(int c)
{
    if (digit(c)) return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Owned by read_table(), outside lua_pcall: Lua errors cannot skip cleanup.
struct Parser {
    lua_State* state;
    FILE* file;
    const char* path;
    int current = ' ';
    int token = 0;
    unsigned line = 1;
    unsigned column = 0;
    std::string text;
    enum { string_token = 256, number_token, name_token };

    [[noreturn]] void fail(const char* message)
    {
        luaL_error(state, "%s:%I:%I: %s", path, static_cast<lua_Integer>(line),
                   static_cast<lua_Integer>(column), message);
        std::abort();
    }
    void advance()
    {
        if (current == '\n') { ++line; column = 0; }
        current = std::fgetc(file);
        if (current == '\r' || current == '\n') {
            const int following = std::fgetc(file);
            if (following != EOF && !((current == '\r' && following == '\n')
                || (current == '\n' && following == '\r'))) std::ungetc(following, file);
            current = '\n';
        }
        ++column;
    }
    void utf8(unsigned value)
    {
        if (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) fail("invalid Unicode escape");
        if (value < 0x80) text += static_cast<char>(value);
        else {
            if (value >= 0x10000) text += static_cast<char>(0xf0 | (value >> 18));
            if (value >= 0x800) text += static_cast<char>((value >= 0x10000 ? 0x80 : 0xe0) | ((value >> 12) & 0x3f));
            text += static_cast<char>((value >= 0x800 ? 0x80 : 0xc0) | ((value >> 6) & 0x3f));
            text += static_cast<char>(0x80 | (value & 0x3f));
        }
    }
    void quoted()
    {
        const int quote = current;
        advance();
        while (current != quote) {
            if (current == EOF || current == '\n' || current == '\r') fail("unterminated string");
            if (current != '\\') { text += static_cast<char>(current); advance(); continue; }
            advance();
            const char* escapes = "abfnrtv\\\"'";
            const char* values = "\a\b\f\n\r\t\v\\\"'";
            const char* found = current > 0 && current < 128 ? std::strchr(escapes, current) : nullptr;
            if (found) { text += values[found - escapes]; advance(); }
            else if (digit(current)) {
                unsigned value = 0;
                for (int i = 0; i < 3 && digit(current); ++i) { value = value * 10 + current - '0'; advance(); }
                if (value > 255) fail("decimal escape exceeds 255");
                text += static_cast<char>(value);
            } else if (current == 'x') {
                unsigned value = 0;
                for (int i = 0; i < 2; ++i) { advance(); if (hex(current) < 0) fail("expected two hex digits"); value = value * 16 + hex(current); }
                text += static_cast<char>(value);
                advance();
            } else if (current == 'u') {
                advance();
                if (current != '{') fail("expected '{' after Unicode escape");
                advance();
                unsigned value = 0;
                int count = 0;
                while (hex(current) >= 0) {
                    if (++count > 6) fail("Unicode escape is too large");
                    value = value * 16 + hex(current); advance();
                }
                if (!count || current != '}') fail("invalid Unicode escape");
                utf8(value); advance();
            } else if (current == 'z') {
                advance(); while (space(current)) advance();
            } else if (current == '\n' || current == '\r') {
                const int first = current; advance();
                if ((first == '\r' && current == '\n') || (first == '\n' && current == '\r')) advance();
                text += '\n';
            } else fail("invalid string escape");
        }
        advance();
    }
    void next()
    {
        text.clear();
        for (;;) {
            while (space(current)) advance();
            if (current != '-') break;
            advance();
            if (current != '-') { text = "-"; break; }
            while (current != EOF && current != '\n') advance();
        }
        if (text.empty() && (current == '\'' || current == '"')) {
            quoted(); token = string_token; return;
        }
        if (!text.empty() || digit(current) || current == '.') {
            while (digit(current)) { text += static_cast<char>(current); advance(); }
            if (current == '.') {
                text += '.'; advance();
                while (digit(current)) { text += static_cast<char>(current); advance(); }
            }
            if (current == 'e' || current == 'E') {
                text += static_cast<char>(current); advance();
                if (current == '+' || current == '-') { text += static_cast<char>(current); advance(); }
                while (digit(current)) { text += static_cast<char>(current); advance(); }
            }
            token = number_token; return;
        }
        if (letter(current)) {
            do { text += static_cast<char>(current); advance(); } while (letter(current) || digit(current));
            token = name_token; return;
        }
        token = current;
        if (current != EOF) advance();
    }
    void expect(int expected)
    {
        if (token != expected) fail("unexpected token");
        next();
    }
    void scalar()
    {
        if (token == string_token) lua_pushlstring(state, text.data(), text.size());
        else if (token == number_token) {
            if (lua_stringtonumber(state, text.c_str()) != text.size() + 1) fail("invalid decimal number");
            if (!std::isfinite(lua_tonumber(state, -1))) fail("number is outside Lua's finite range");
        } else if (token == name_token && (text == "true" || text == "false")) lua_pushboolean(state, text == "true");
        else fail("expected a string, decimal number, boolean, or table");
        next();
    }
    void value(unsigned depth)
    {
        if (depth > max_depth) fail("table nesting exceeds eight levels");
        luaL_checkstack(state, 5, nullptr);
        if (token != '{') { scalar(); return; }
        next();
        lua_newtable(state);
        const int table = lua_gettop(state);
        lua_Integer sequence = 0;
        while (token != '}') {
            if (token == '[') {
                next(); scalar(); expect(']'); expect('='); value(depth + 1);
            } else if (token == name_token && text != "true" && text != "false") {
                // Lua keywords cannot be bare field names.
                if (keyword(text)) fail("reserved word used as a field name");
                lua_pushlstring(state, text.data(), text.size());
                next(); expect('='); value(depth + 1);
            } else {
                lua_pushinteger(state, ++sequence); value(depth + 1);
            }
            lua_pushvalue(state, -2);
            lua_rawget(state, table);
            if (!lua_isnil(state, -1)) fail("duplicate table key");
            lua_pop(state, 1);
            lua_rawset(state, table);
            if (token != ',' && token != ';') break;
            next();
        }
        expect('}');
    }
};

int parse_document(lua_State* state)
{
    auto& parser = *static_cast<Parser*>(lua_touserdata(state, 1));
    parser.next();
    if (parser.token != '{') parser.fail("expected a table literal starting with '{'");
    parser.value(0);
    if (parser.token != EOF) parser.fail("unexpected content after table");
    return 1;
}

std::string_view lua_string(lua_State* state, int index)
{
    size_t size;
    const char* data = lua_tolstring(state, index, &size);
    return {data, size};
}

struct TableWrite {
    std::string document;
    std::array<const void*, max_depth + 1> ancestors{};
};

void encode_value(lua_State* state, int index, TableWrite& output, unsigned depth)
{
    if (depth > max_depth) luaL_error(state, "table nesting exceeds eight levels");
    luaL_checkstack(state, 4, nullptr);
    switch (lua_type(state, index)) {
    case LUA_TSTRING:
        output.document += '"';
        for (unsigned char byte : lua_string(state, index)) {
            if (byte == '"' || byte == '\\') { output.document += '\\'; output.document += static_cast<char>(byte); }
            else if (byte < 32 || byte >= 127) {
                char escape[5];
                std::snprintf(escape, sizeof(escape), "\\%03u", static_cast<unsigned>(byte));
                output.document += escape;
            } else output.document += static_cast<char>(byte);
        }
        output.document += '"';
        break;
    case LUA_TNUMBER: {
        if (!std::isfinite(lua_tonumber(state, index))) luaL_error(state, "cannot serialize a non-finite number");
        // Preserve integer/float identity and enough digits to round-trip.
        lua_pushvalue(state, index);
        if (lua_isinteger(state, -1)) output.document += lua_string(state, -1);
        else {
            char number[64];
            std::snprintf(number, sizeof(number), "%.*g", std::numeric_limits<lua_Number>::max_digits10,
                          static_cast<double>(lua_tonumber(state, -1)));
            output.document += number;
            if (!std::strpbrk(number, ".eE")) output.document += ".0";
        }
        lua_pop(state, 1);
        break;
    }
    case LUA_TBOOLEAN:
        output.document += lua_toboolean(state, index) ? "true" : "false";
        break;
    case LUA_TTABLE: {
        const void* identity = lua_topointer(state, index);
        const auto end = output.ancestors.begin() + depth;
        if (std::find(output.ancestors.begin(), end, identity) != end) luaL_error(state, "cannot serialize a cyclic table");
        output.ancestors[depth] = identity;
        output.document += "{\n";
        lua_pushnil(state);
        while (lua_next(state, index)) {
            const int key_type = lua_type(state, -2);
            if (key_type != LUA_TSTRING && key_type != LUA_TNUMBER && key_type != LUA_TBOOLEAN)
                luaL_error(state, "table keys must be strings, numbers, or booleans");
            output.document.append((depth + 1) * 4, ' ');
            const auto key = key_type == LUA_TSTRING ? lua_string(state, -2) : std::string_view{};
            if (!key.empty() && letter(static_cast<unsigned char>(key.front())) && !keyword(key)
                && std::all_of(key.begin(), key.end(), [](unsigned char c) { return letter(c) || digit(c); })) {
                output.document += key;
                output.document += " = ";
            } else {
                output.document += '[';
                encode_value(state, lua_gettop(state) - 1, output, depth + 1);
                output.document += "] = ";
            }
            encode_value(state, lua_gettop(state), output, depth + 1);
            output.document += ",\n";
            lua_pop(state, 1);
        }
        output.document.append(depth * 4, ' ');
        output.document += '}';
        break;
    }
    default: luaL_error(state, "cannot serialize %s", luaL_typename(state, index));
    }
}

int encode_document(lua_State* state)
{
    auto& output = *static_cast<TableWrite*>(lua_touserdata(state, 2));
    encode_value(state, 1, output, 0);
    output.document += '\n';
    return 0;
}

std::string sibling_path(std::string_view path, const char* extension)
{
    static std::atomic<unsigned> sequence{0};
    const auto start = path.find_last_of("/\\") + 1;
    const char first = path[start];
    const char prefix = first == 't' || first == 'T' ? 'u' : 't';
    char name[13];
    std::snprintf(name, sizeof(name), "%c%07x.%s", prefix, sequence.fetch_add(1) & 0x0fffffff, extension);
    std::string sibling(path.substr(0, start));
    sibling += name;
    return sibling;
}

int write_staged(const char* path, const std::string& document, std::string& staged)
{
    for (int attempt = 0; attempt < 32; ++attempt) {
        staged = sibling_path(path, "tmp");
        int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_BINARY
        flags |= O_BINARY;
#endif
        const int descriptor = open(staged.c_str(), flags, 0666);
        if (descriptor < 0) {
            if (errno != EEXIST) {
                return errno;
            }
            continue;
        }
        FILE* file = fdopen(descriptor, "wb");
        if (!file) {
            const int error = errno;
            close(descriptor);
            unlink(staged.c_str());
            return error;
        }
        errno = 0;
        int error = std::fwrite(document.data(), 1, document.size(), file) == document.size()
            ? 0 : (errno ? errno : EIO);
        if (std::fclose(file) != 0 && !error) {
            error = errno ? errno : EIO;
        }
        if (error) {
            unlink(staged.c_str());
        }
        return error;
    }
    return EEXIST;
}

int replace_file(const char* path, const std::string& staged, std::string& retained_backup)
{
    if (std::rename(staged.c_str(), path) == 0) {
        return 0;
    }
    const int error = errno;
    if (error != EEXIST) {
        return error;
    }
    // FatFs rejects replacing an existing destination. Move it aside first.
    struct stat info{};
    if (stat(path, &info) != 0) {
        return errno;
    }
    if (!S_ISREG(info.st_mode)) {
        return EISDIR;
    }
    for (int attempt = 0; attempt < 32; ++attempt) {
        const auto backup = sibling_path(path, "bak");
        if (std::rename(path, backup.c_str()) != 0) {
            if (errno != EEXIST) {
                return errno;
            }
            continue;
        }
        if (std::rename(staged.c_str(), path) != 0) {
            const int replace_error = errno;
            if (std::rename(backup.c_str(), path) != 0) {
                retained_backup = backup;
            }
            return replace_error;
        }
        if (unlink(backup.c_str()) != 0) {
            retained_backup = backup;
        }
        return 0;
    }
    return EEXIST;
}

}

int read_table(lua_State* state)
{
    luaL_checktype(state, 1, LUA_TSTRING);
    const auto path = lua_string(state, 1);
    luaL_argcheck(state, !path.empty() && path.find('\0') == std::string_view::npos, 1, "expected a file path");
    lua_settop(state, 1);
    luaL_checkstack(state, 2, nullptr);
    lua_pushcfunction(state, parse_document);
    auto* file = std::fopen(path.data(), "rb");
    if (!file) return luaL_fileresult(state, 0, path.data());
    int status;
    int file_error;
    {
        Parser parser{state, file, path.data(), ' ', 0, 1, 0, {}};
        lua_pushlightuserdata(state, &parser);
        status = lua_pcall(state, 1, 1, 0);
        file_error = std::ferror(file) ? (errno ? errno : EIO) : 0;
        if (std::fclose(file) != 0 && !file_error) file_error = errno ? errno : EIO;
    }
    if (file_error) {
        errno = file_error;
        return luaL_fileresult(state, 0, path.data());
    }
    if (status == LUA_ERRRUN) {
        lua_pushnil(state);
        lua_insert(state, -2);
        return 2;
    }
    if (status != LUA_OK) return lua_error(state);
    return 1;
}
int write_table(lua_State* state)
{
    luaL_checktype(state, 1, LUA_TSTRING);
    const auto path = lua_string(state, 1);
    luaL_argcheck(state, !path.empty() && path.find('\0') == std::string_view::npos
                  && path.back() != '/' && path.back() != '\\', 1, "expected a file path");
    luaL_checktype(state, 2, LUA_TTABLE);
    lua_settop(state, 2);
    luaL_checkstack(state, 3, nullptr);
    lua_pushcfunction(state, encode_document);
    lua_pushvalue(state, 2);

    int file_error = 0;
    int status;
    std::array<char, 13> retained_backup{};
    {
        TableWrite output;
        lua_pushlightuserdata(state, &output);
        // Keep native allocations outside the protected Lua call.
        status = lua_pcall(state, 2, 0, 0);
        if (status == LUA_OK) {
            std::string staged;
            std::string backup;
            file_error = write_staged(path.data(), output.document, staged);
            if (!file_error) {
                file_error = replace_file(path.data(), staged, backup);
                if (file_error) {
                    unlink(staged.c_str());
                }
            }
            if (!backup.empty()) {
                std::copy_n(backup.end() - 12, 12, retained_backup.begin());
            }
        }
    }
    if (status == LUA_ERRRUN) {
        lua_pushnil(state);
        lua_insert(state, -2);
        return 2;
    }
    if (status != LUA_OK) {
        return lua_error(state);
    }
    if (retained_backup[0]) {
        if (file_error) {
            lua_pushnil(state);
            lua_pushfstring(state, "%s: replacement failed, original kept in sibling %s",
                            path.data(), retained_backup.data());
            lua_pushinteger(state, file_error);
            return 3;
        }
        lua_pushboolean(state, 1);
        lua_pushfstring(state, "%s: backup cleanup failed for sibling %s",
                        path.data(), retained_backup.data());
        return 2;
    }
    errno = file_error;
    return luaL_fileresult(state, !file_error, path.data());
}

}

