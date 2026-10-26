// Feed fuzzer bytes to OCIO's LUT/transform file loaders. The format is picked by the first
// input byte (a fixed extension table; OCIO dispatches on the file extension), so the bytes are
// written to a temp file with that extension and loaded through a FileTransform.
#include <OpenColorIO/OpenColorIO.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

namespace OCIO = OCIO_NAMESPACE;

static const char * const kExtensions[] = {
    ".cdl", ".3dl", ".cube", ".cc", ".clf", ".ctf", ".lut", ".csp", ".look", ".mga", ".m3d",
    ".itx", ".spi1d", ".spi3d", ".cub", ".ccc", ".vf", ".spimtx", ".icc", ".icm", ".pf",
};
static const size_t kNumExtensions = sizeof(kExtensions) / sizeof(kExtensions[0]);

static const OCIO::GpuLanguage kLanguages[] = {
    OCIO::GPU_LANGUAGE_GLSL_1_2, OCIO::GPU_LANGUAGE_GLSL_4_0, OCIO::GPU_LANGUAGE_HLSL_DX11,
    OCIO::GPU_LANGUAGE_MSL_2_0,
};

extern "C" int LLVMFuzzerTestOneInput(const uint8_t * data, size_t size)
{
    if (size < 3) return -1;

    const char * ext = kExtensions[data[0] % kNumExtensions];
    const uint8_t flags = data[1];
    data += 2;
    size -= 2;

    const char * tmpdir = getenv("TMPDIR");
    std::string path = std::string(tmpdir && *tmpdir ? tmpdir : "/tmp") + "/ocio_fuzz_XXXXXX" + ext;
    const int fd = mkstemps(&path[0], static_cast<int>(strlen(ext)));
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
        OCIO::FileTransformRcPtr ft = OCIO::FileTransform::Create();
        ft->setSrc(path.c_str());
        ft->setCCCId("0");
        ft->setDirection((flags & 1) ? OCIO::TRANSFORM_DIR_INVERSE : OCIO::TRANSFORM_DIR_FORWARD);
        ft->setInterpolation((flags & 2) ? OCIO::INTERP_TETRAHEDRAL : OCIO::INTERP_LINEAR);

        OCIO::ConstConfigRcPtr config = OCIO::Config::CreateRaw();
        OCIO::ConstProcessorRcPtr proc = config->getProcessor(ft);

        OCIO::ConstCPUProcessorRcPtr cpu = proc->getDefaultCPUProcessor();
        float px[8] = { 0.18f, 0.5f, 0.9f, 1.0f, -0.1f, 2.5f, 0.0f, 0.25f };
        cpu->applyRGBA(px);
        cpu->applyRGBA(px + 4);

        if (flags & 4)
        {
            OCIO::GpuShaderDescRcPtr desc = OCIO::GpuShaderDesc::CreateShaderDesc();
            desc->setLanguage(kLanguages[(flags >> 3) & 3]);
            proc->getDefaultGPUProcessor()->extractGpuShaderInfo(desc);
        }
    }
    catch (OCIO::Exception &)
    {
        ret = -1;
    }

    unlink(path.c_str());
    return ret;
}
