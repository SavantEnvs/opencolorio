// Parse an OCIO YAML config from memory, validate/serialize it and run a few pixels through
// processors built from it (color-space pairs and the first display/view).
#include <OpenColorIO/OpenColorIO.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <sstream>
#include <string>

namespace OCIO = OCIO_NAMESPACE;

static void ApplyPixels(const OCIO::ConstProcessorRcPtr & proc)
{
    OCIO::ConstCPUProcessorRcPtr cpu = proc->getDefaultCPUProcessor();
    float px[8] = { 0.18f, 0.5f, 0.9f, 1.0f, -0.1f, 2.5f, 0.0f, 0.25f };
    cpu->applyRGBA(px);
    cpu->applyRGBA(px + 4);

    OCIO::GpuShaderDescRcPtr desc = OCIO::GpuShaderDesc::CreateShaderDesc();
    desc->setLanguage(OCIO::GPU_LANGUAGE_GLSL_4_0);
    proc->getDefaultGPUProcessor()->extractGpuShaderInfo(desc);
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t * data, size_t size)
{
    std::istringstream is(std::string(reinterpret_cast<const char *>(data), size));

    OCIO::ConstConfigRcPtr config;
    try
    {
        config = OCIO::Config::CreateFromStream(is);
    }
    catch (OCIO::Exception &)
    {
        return -1;
    }

    try
    {
        config->validate();
        std::ostringstream os;
        config->serialize(os);
        (void)config->getCacheID();

        const int nbCS = std::min(config->getNumColorSpaces(), 3);
        for (int i = 0; i < nbCS; ++i)
        {
            for (int j = 0; j < nbCS; ++j)
            {
                ApplyPixels(config->getProcessor(config->getColorSpaceNameByIndex(i),
                                                 config->getColorSpaceNameByIndex(j)));
            }
        }

        if (config->getNumDisplays() > 0)
        {
            const char * display = config->getDisplay(0);
            if (config->getNumViews(display) > 0 && nbCS > 0)
            {
                OCIO::DisplayViewTransformRcPtr dvt = OCIO::DisplayViewTransform::Create();
                dvt->setSrc(config->getColorSpaceNameByIndex(0));
                dvt->setDisplay(display);
                dvt->setView(config->getView(display, 0));
                ApplyPixels(config->getProcessor(dvt));
            }
        }
    }
    catch (OCIO::Exception &)
    {
    }
    return 0;
}
