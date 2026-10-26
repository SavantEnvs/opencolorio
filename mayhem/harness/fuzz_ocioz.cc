// Load an OCIOZ config archive (a zip holding config.ocio plus its LUT files) from a temp file,
// then validate it and run a few pixels through the first color-space pair.
#include <OpenColorIO/OpenColorIO.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <unistd.h>

namespace OCIO = OCIO_NAMESPACE;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t * data, size_t size)
{
    if (size == 0) return -1;

    const char * tmpdir = getenv("TMPDIR");
    std::string path = std::string(tmpdir && *tmpdir ? tmpdir : "/tmp") + "/ocio_fuzz_XXXXXX.ocioz";
    const int fd = mkstemps(&path[0], 6);
    if (fd < 0) return -1;
    size_t off = 0;
    while (off < size)
    {
        const ssize_t n = write(fd, data + off, size - off);
        if (n <= 0) break;
        off += static_cast<size_t>(n);
    }
    close(fd);

    int ret = 0;
    try
    {
        OCIO::ConstConfigRcPtr config = OCIO::Config::CreateFromFile(path.c_str());
        config->validate();
        if (config->getNumColorSpaces() > 1)
        {
            OCIO::ConstProcessorRcPtr proc = config->getProcessor(
                config->getColorSpaceNameByIndex(0), config->getColorSpaceNameByIndex(1));
            float px[4] = { 0.18f, 0.5f, 0.9f, 1.0f };
            proc->getDefaultCPUProcessor()->applyRGBA(px);
        }
    }
    catch (OCIO::Exception &)
    {
        ret = -1;
    }

    unlink(path.c_str());
    return ret;
}
