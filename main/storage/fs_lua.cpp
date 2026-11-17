#include "fs_lua.hpp"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "lua/module_definition.hpp"

extern "C" {
#include "ff.h"
#include "lauxlib.h"
}

namespace tabos::fs {

int read_table(lua_State* state);
int write_table(lua_State* state);

namespace {
int directory_error(lua_State* state, const char* operation, const char* path)
{
    const int code = errno;
    const char* context = lua_pushfstring(state, "%s %s", operation, path);
    errno = code;
    return luaL_fileresult(state, 0, context);
}

int read_directory(lua_State* state)
{
    auto* directory = static_cast<DIR*>(lua_touserdata(state, 1));
    const char* path = lua_tostring(state, 2);
    lua_newtable(state);
    lua_Integer index = 1;
    for (;;) {
        errno = 0;
        const auto* entry = readdir(directory);
        if (!entry) {
            return errno == 0 ? 1 : directory_error(state, "readdir", path);
        }
        if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        lua_createtable(state, 0, 2);
        lua_pushstring(state, entry->d_name);
        lua_setfield(state, -2, "name");
        if (entry->d_type == DT_DIR || entry->d_type == DT_REG) {
            lua_pushstring(state, entry->d_type == DT_DIR ? "dir" : "file");
            lua_setfield(state, -2, "type");
        }
        lua_rawseti(state, -2, index++);
    }
}

int list(lua_State* state)
{
    const char* path = luaL_checkstring(state, 1);
    lua_settop(state, 1);
    luaL_checkstack(state, 3, nullptr);
    lua_pushcfunction(state, read_directory);
    auto* directory = opendir(path);
    if (!directory) {
        return directory_error(state, "opendir", path);
    }

    // Protect table construction so Lua allocation errors still close the directory.
    lua_pushlightuserdata(state, directory);
    lua_pushvalue(state, 1);
    const int status = lua_pcall(state, 2, LUA_MULTRET, 0);
    const int close_status = closedir(directory);
    const int close_error = errno;
    if (status != LUA_OK) {
        return lua_error(state);
    }
    const int result_count = lua_gettop(state) - 1;
    if (result_count == 1 && close_status != 0) {
        errno = close_error;
        return directory_error(state, "closedir", path);
    }
    return result_count;
}

int file_stat(lua_State* state)
{
    const char* path = luaL_checkstring(state, 1);
    struct stat info{};
    if (stat(path, &info) != 0) {
        return luaL_fileresult(state, 0, path);
    }

    lua_createtable(state, 0, 3);
    lua_pushstring(state, S_ISDIR(info.st_mode) ? "dir" : "file");
    lua_setfield(state, -2, "type");
    lua_pushinteger(state, info.st_size);
    lua_setfield(state, -2, "size");
    lua_pushinteger(state, info.st_mtime);
    lua_setfield(state, -2, "mtime");
    return 1;
}

int close_new_file(lua_State* state)
{
    auto* stream = static_cast<luaL_Stream*>(luaL_checkudata(state, 1, LUA_FILEHANDLE));
    errno = 0;
    const int result = std::fclose(stream->f);
    stream->f = nullptr;
    return luaL_fileresult(state, result == 0, nullptr);
}

int open_new_file(lua_State* state)
{
    const char* path = luaL_checkstring(state, 1);
    auto* stream = static_cast<luaL_Stream*>(lua_newuserdatauv(state, sizeof(luaL_Stream), 0));
    stream->f = nullptr;
    stream->closef = nullptr;
    luaL_setmetatable(state, LUA_FILEHANDLE);

    const int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0666);
    if (descriptor < 0) {
        return luaL_fileresult(state, 0, path);
    }
    stream->f = fdopen(descriptor, "wb");
    if (!stream->f) {
        const int error = errno;
        close(descriptor);
        unlink(path);
        errno = error;
        return luaL_fileresult(state, 0, path);
    }
    stream->closef = close_new_file;
    return 1;
}

int fat_name_key(lua_State* state)
{
    size_t size;
    const auto* name = reinterpret_cast<const unsigned char*>(luaL_checklstring(state, 1, &size));
    luaL_Buffer buffer;
    luaL_buffinit(state, &buffer);
    for (size_t index = 0; index < size;) {
        const auto lead = name[index];
        if (lead < 0x80) {
            luaL_addchar(&buffer, static_cast<char>(ff_wtoupper(lead)));
            ++index;
            continue;
        }
        const int bytes = lead >= 0xc2 && lead <= 0xdf ? 2
            : lead >= 0xe0 && lead <= 0xef ? 3 : 0;
        if (bytes && size - index >= static_cast<size_t>(bytes)) {
            std::uint32_t codepoint = lead & (0x7f >> bytes);
            int offset = 1;
            for (; offset < bytes && (name[index + offset] & 0xc0) == 0x80; ++offset) {
                codepoint = (codepoint << 6) | (name[index + offset] & 0x3f);
            }
            if (offset == bytes && (bytes == 2 || codepoint >= 0x800)
                && !(codepoint >= 0xd800 && codepoint <= 0xdfff)) {
                lua_pushfstring(state, "%U", static_cast<unsigned long>(ff_wtoupper(codepoint)));
                luaL_addvalue(&buffer);
                index += bytes;
                continue;
            }
        }
        // FatFs case mappings are for BMP characters. Preserve every other byte.
        luaL_addchar(&buffer, static_cast<char>(lead));
        ++index;
    }
    luaL_pushresult(&buffer);
    return 1;
}

int make_directory(lua_State* state)
{
    const char* path = luaL_checkstring(state, 1);
    return luaL_fileresult(state, mkdir(path, 0777) == 0, path);
}

int rename_path(lua_State* state)
{
    const char* from = luaL_checkstring(state, 1);
    const char* to = luaL_checkstring(state, 2);
    return luaL_fileresult(state, std::rename(from, to) == 0, nullptr);
}

int remove_path(lua_State* state)
{
    const char* path = luaL_checkstring(state, 1);
    // ESP-IDF's FAT unlink handles both files and empty directories.
    return luaL_fileresult(state, unlink(path) == 0, path);
}

int push_fs_table(lua_State* state)
{
    const luaL_Reg functions[] = {
        {"list", list},
        {"stat", file_stat},
        {"open_new", open_new_file},
        {"fat_name_key", fat_name_key},
        {"read_table", read_table},
        {"write_table", write_table},
        {"mkdir", make_directory},
        {"rename", rename_path},
        {"remove", remove_path},
        {nullptr, nullptr},
    };
    luaL_newlib(state, functions);
    return 1;
}

}

lua_vm::Module lua_module()
{
    static const lua_vm::Module::Definition definition{"fs", push_fs_table};
    return lua_vm::Module{definition};
}

}
