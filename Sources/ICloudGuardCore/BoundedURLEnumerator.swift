import Foundation

public enum BoundedURLEnumerator {
    public static func forEachURL<S: Sequence>(
        in sequence: S,
        shouldStop: () -> Bool,
        body: (URL) -> Void
    ) {
        for element in sequence {
            if shouldStop() {
                break
            }
            guard let url = element as? URL else {
                continue
            }
            autoreleasepool {
                body(url)
            }
        }
    }
}
