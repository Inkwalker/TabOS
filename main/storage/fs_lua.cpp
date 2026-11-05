#include "fs_lua.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include "lua/module_definition.hpp"

extern "C" {
#include "lauxlib.h"
}

namespace tabos::fs {
namespace {

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
            return errno == 0 ? 1 : luaL_fileresult(state, 0, path);
        }
        if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        lua_pushstring(state, entry->d_name);
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
        return luaL_fileresult(state, 0, path);
    }

    // Protect table construction so Lua allocation errors still close the directory.
    lua_pushlightuserdata(state, directory);
    lua_pushvalue(state, 1);
    const int status = lua_pcall(state, 2, LUA_MULTRET, 0);
    const int close_status = closedir(directory);
    if (status != LUA_OK) {
        return lua_error(state);
    }
    const int result_count = lua_gettop(state) - 1;
    if (result_count == 1 && close_status != 0) {
        return luaL_fileresult(state, 0, path);
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
    lua_pushstring(state, S_ISDIR(info.st_mode) ? "directory" : "file");
    lua_setfield(state, -2, "type");
    lua_pushinteger(state, info.st_size);
    lua_setfield(state, -2, "size");
    lua_pushinteger(state, info.st_mtime);
    lua_setfield(state, -2, "mtime");
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
