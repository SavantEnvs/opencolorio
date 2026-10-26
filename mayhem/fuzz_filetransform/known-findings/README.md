# ICC reader: invalid enum values (UBSan `enum`)

`icc-invalid-tag-signature-enum.bin` (an `.icc` input: selector bytes `12 04` + a sampleicc test profile
whose first tag signature is overwritten with `a5a5a5a5`) trips
`runtime error: load of value 2779096485, which is not a valid value for type 'icTagSignature'`
at `ext/sampleicc/src/include/iccProfileReader.h:644` (and the same for `icTagTypeSignature` at `:707`).

Cause: the bundled sampleicc reader reads the 32-bit tag signature / tag type from the file straight into
a C++ enum, which is undefined for values outside the enumerators. Impact: UB only in practice (the value is
only compared/looked up afterwards). Fix upstream: read into `uint32_t` and cast after the lookup.

Because this fires on almost any malformed ICC input, the fuzz build relaxes only the UBSan `enum` check
(`-fno-sanitize=enum` in `mayhem/build.sh`); ASan and the other UBSan checks stay halting.
