// 一个使用 release 测量搜索速度的小型设备。
//   swift run -c release search-bench <文件> <关键词>
import Foundation
import SiftEditorCore

let args = CommandLine.arguments
// 如果第二个参数是“scan”，则只是扫描而不进行匹配（下限为 mmap）。
if args.count == 3, args[2] == "scan" {
    guard let r = SearchBench.scan(path: args[1]) else {
        FileHandle.standardError.write(Data("无法打开: \(args[1])\n".utf8)); exit(1)
    }
    print("\(r.encoding)\t\(r.bytes) byte\t换行 \(r.matchedLines)\t"
          + String(format: "%.2f", r.seconds) + " s")
    exit(0)
}

guard args.count >= 3 else {
    FileHandle.standardError.write(Data("用法: search-bench <文件> <关键词>\n".utf8))
    exit(1)
}
guard let r = SearchBench.run(path: args[1], term: args[2]) else {
    FileHandle.standardError.write(Data("无法打开: \(args[1])\n".utf8))
    exit(1)
}
print("\(r.encoding)\t\(r.bytes) byte\t\(args[2])\t\(r.matchedLines) 行\t"
      + String(format: "%.2f", r.seconds) + " s")
