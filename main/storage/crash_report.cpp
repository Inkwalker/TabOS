#include "crash_report.hpp"

#include "sdkconfig.h"

#if CONFIG_ESP_COREDUMP_ENABLE_TO_FLASH && CONFIG_ESP_COREDUMP_DATA_FORMAT_ELF

#include <algorithm>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_core_dump.h"
#include "esp_log.h"
#include "esp_partition.h"

namespace tabos::storage {
namespace {

constexpr const char* tag = "crash_report";
constexpr const char* report_root = "/sd/crash";
constexpr size_t minimum_image_size = 64; // Reject undersized images before checking the checksum.

struct ReportPaths {
    char complete[40];
    char pending[40];
    char summary[56];
    char dump[56];
};

bool create_report_directory(ReportPaths& paths)
{
    if (mkdir(report_root, 0777) != 0 && errno != EEXIST) {
        return false;
    }

    // Export before starting MTP, while this code is the only writer to the card.
    for (unsigned index = 1; ; ++index) {
        std::snprintf(paths.complete, sizeof(paths.complete), "%s/panic-%06u", report_root, index);
        struct stat existing{};
        if (stat(paths.complete, &existing) == 0) {
            continue;
        }
        if (errno != ENOENT) {
            return false;
        }

        std::snprintf(paths.pending, sizeof(paths.pending), "%s/.pending-%06u", report_root, index);
        if (mkdir(paths.pending, 0777) == 0) {
            std::snprintf(paths.summary, sizeof(paths.summary), "%s/panic.txt", paths.pending);
            std::snprintf(paths.dump, sizeof(paths.dump), "%s/coredump.bin", paths.pending);
            return true;
        }
        if (errno != EEXIST) {
            return false;
        }
    }
}

bool write_summary(const char* path, size_t size, bool valid)
{
    auto* file = std::fopen(path, "w");
    if (!file) {
        return false;
    }

    bool ok = std::fprintf(file, "TabOS firmware panic\nCore dump size: %zu bytes\n", size) >= 0;
    if (valid) {
        char reason[256];
        if (esp_core_dump_get_panic_reason(reason, sizeof(reason)) == ESP_OK) {
            ok &= std::fprintf(file, "Panic reason: %s\n", reason) >= 0;
        }
        esp_core_dump_summary_t summary{};
        if (esp_core_dump_get_summary(&summary) == ESP_OK) {
            ok &= std::fprintf(file, "Task: %.16s\nPC: 0x%08" PRIx32 "\n"
                                    "RISC-V cause: 0x%08" PRIx32 "\n"
                                    "Firmware ELF SHA-256 prefix: %.*s\n",
                               summary.exc_task, summary.exc_pc, summary.ex_info.mcause,
                               static_cast<int>(sizeof(summary.app_elf_sha256)), summary.app_elf_sha256) >= 0;
        }
    } else {
        ok &= std::fputs("Core dump failed validation. The raw flash partition was saved.\n", file) >= 0;
    }
    return std::fclose(file) == 0 && ok;
}

bool write_dump(const char* path, const esp_partition_t* partition, size_t size)
{
    auto* file = std::fopen(path, "wb");
    if (!file) {
        return false;
    }

    uint8_t buffer[512];
    size_t offset = 0;
    while (offset < size) {
        const size_t chunk = std::min(sizeof(buffer), size - offset);
        const esp_err_t result = esp_partition_read(partition, offset, buffer, chunk);
        if (result != ESP_OK) {
            ESP_LOGW(tag, "Could not read core dump: %s", esp_err_to_name(result));
            break;
        }
        if (std::fwrite(buffer, 1, chunk, file) != chunk) {
            break;
        }
        offset += chunk;
    }
    return std::fclose(file) == 0 && offset == size;
}

} // namespace

void export_crash_report()
{
    const auto* partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
                                                     ESP_PARTITION_SUBTYPE_DATA_COREDUMP, nullptr);
    if (!partition) {
        ESP_LOGW(tag, "Core dump partition missing");
        return;
    }

    // ESP-IDF stores the image length in the first word and leaves it erased when empty.
    uint32_t image_size = 0;
    esp_err_t result = esp_partition_read(partition, 0, &image_size, sizeof(image_size));
    if (result != ESP_OK) {
        ESP_LOGW(tag, "Could not read core dump header: %s", esp_err_to_name(result));
        return;
    }
    if (image_size == UINT32_MAX) {
        return;
    }

    if (image_size < minimum_image_size || image_size > partition->size) {
        result = ESP_ERR_INVALID_SIZE;
    } else {
        result = esp_core_dump_image_check();
    }
    const bool valid = result == ESP_OK;
    if (!valid && result != ESP_ERR_INVALID_SIZE && result != ESP_ERR_INVALID_CRC) {
        ESP_LOGW(tag, "Could not validate core dump: %s", esp_err_to_name(result));
        return;
    }
    const size_t export_size = valid ? image_size : partition->size;

    ReportPaths paths;
    if (!create_report_directory(paths)) {
        ESP_LOGW(tag, "Could not create crash report on SD (errno %d)", errno);
        return;
    }
    if (!write_summary(paths.summary, export_size, valid) || !write_dump(paths.dump, partition, export_size)) {
        ESP_LOGW(tag, "Could not write crash report to SD. Core dump retained in flash");
        unlink(paths.dump);
        unlink(paths.summary);
        rmdir(paths.pending);
        return;
    }
    if (std::rename(paths.pending, paths.complete) != 0) {
        ESP_LOGW(tag, "Could not publish crash report on SD (errno %d)", errno);
        return;
    }

    ESP_LOGI(tag, "Crash report saved to %s", paths.complete);
    result = esp_core_dump_image_erase();
    if (result != ESP_OK) {
        ESP_LOGW(tag, "Could not clear exported core dump: %s", esp_err_to_name(result));
    }
}

}

#else

void tabos::storage::export_crash_report() {}

#endif
