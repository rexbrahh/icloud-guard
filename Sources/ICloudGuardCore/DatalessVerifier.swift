import Darwin
import Foundation

/// Verifies post-eviction state via `lstat(2)`: a truly evicted file carries
/// the APFS SF_DATALESS flag (0x40000000) with zero allocated blocks.
public enum DatalessVerifier {
    public static func verify(at path: String) -> EvictionVerification {
        var statInfo = stat()
        let result = path.withCString { ptr in
            lstat(ptr, &statInfo)
        }

        guard result == 0 else {
            return EvictionVerification(
                absolutePath: path,
                isDataless: false,
                fileAllocatedSize: 0,
                fileSize: 0
            )
        }

        return EvictionVerification(
            absolutePath: path,
            isDataless: (statInfo.st_flags & SF_DATALESS) != 0,
            fileAllocatedSize: Int64(statInfo.st_blocks) * 512,
            fileSize: Int64(statInfo.st_size)
        )
    }
}
