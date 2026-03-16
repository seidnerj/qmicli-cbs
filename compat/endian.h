/*
 * Compatibility shim for <endian.h> on macOS.
 *
 * Linux provides <endian.h> with htobe16/be16toh etc.
 * macOS 26+ provides these in <sys/endian.h>.
 * Older macOS provides equivalent functions in <libkern/OSByteOrder.h>.
 * On Linux, this file delegates to the real <endian.h> via #include_next.
 */

#ifdef __APPLE__
#  if __has_include(<sys/endian.h>)
#    include <sys/endian.h>
#  else
#    include <libkern/OSByteOrder.h>
#    define htobe16(x) OSSwapHostToBigInt16(x)
#    define be16toh(x) OSSwapBigToHostInt16(x)
#    define htobe32(x) OSSwapHostToBigInt32(x)
#    define be32toh(x) OSSwapBigToHostInt32(x)
#    define htobe64(x) OSSwapHostToBigInt64(x)
#    define be64toh(x) OSSwapBigToHostInt64(x)
#    define htole16(x) OSSwapHostToLittleInt16(x)
#    define le16toh(x) OSSwapLittleToHostInt16(x)
#    define htole32(x) OSSwapHostToLittleInt32(x)
#    define le32toh(x) OSSwapLittleToHostInt32(x)
#    define htole64(x) OSSwapHostToLittleInt64(x)
#    define le64toh(x) OSSwapLittleToHostInt64(x)
#  endif
#else
#  include_next <endian.h>
#endif
