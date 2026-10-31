import Foundation

/// 폴더 내용이 바뀌면 알려줍니다. 네트워크 폴더는 서버 쪽 변경을 감지하지 못할 수 있습니다.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pendingNotification: DispatchWorkItem?
    private let onChange: () -> Void
    
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }
    
    deinit {
        source?.cancel()
    }
    
    func watch(_ url: URL) {
        source?.cancel()
        source = nil
        
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        newSource.setEventHandler { [weak self] in self?.scheduleNotification() }
        newSource.setCancelHandler { close(descriptor) }
        newSource.resume()
        source = newSource
    }
    
    /// 연속된 변경을 한 번의 새로고침으로 묶습니다.
    private func scheduleNotification() {
        pendingNotification?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingNotification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
