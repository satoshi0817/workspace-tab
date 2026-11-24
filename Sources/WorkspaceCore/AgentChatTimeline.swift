import Foundation

/// How a chat reads on screen: messages, with the agent's tool calls between them
/// folded into one item, and Notion's reply markup turned into blocks.
extension AgentChat {
    /// One tool call, with whether its result came back and whether it failed.
    public struct Step:Equatable,Identifiable {
        public let id:String
        public let toolName:String
        public let finished:Bool
        public let failed:Bool
    }
    public enum Item:Equatable,Identifiable {
        case message(Event)
        /// Tool calls between two messages, named after the first call so the item keeps its identity while it grows.
        case steps(id:String,[Step])
        case status(Event)
        public var id:String {
            switch self {
            case .message(let event),.status(let event):return event.id
            case .steps(let id,_):return "steps-"+id
            }
        }
    }
    public static func timeline(_ events:[Event])->[Item] {
        var results:[String:Event]=[:]
        for event in events where event.type == "agent.tool_result" {if let call=event.toolUseID {results[call]=event}}
        var items:[Item]=[],steps:[Step]=[]
        func flush() {
            if let first=steps.first {items.append(.steps(id:first.id,steps))}
            steps=[]
        }
        for event in events {
            switch event.type {
            case "user.message","agent.message":
                if event.visible {flush();items.append(.message(event))}
            case "agent.tool_use":
                let result=results[event.id]
                steps.append(Step(id:event.id,toolName:event.toolName ?? "",finished:result != nil,failed:result?.failed ?? false))
            case "session.status":
                if let status=event.status,status != "completed" {flush();items.append(.status(event))}
            default:break
            }
        }
        flush()
        return items
    }
    /// Newly polled events replace their copies; older ones loaded earlier stay in front.
    public static func merge(_ earlier:[Event],_ newest:[Event])->[Event] {
        guard let start=newest.map(\.sequence).min() else{return earlier}
        return earlier.filter{$0.sequence<start}+newest.sorted{$0.sequence<$1.sequence}
    }

    // MARK: Chat links
    /// The chat a Notion address shows (`/chat?t=<id>`, or a page with the chat open beside it).
    public static func chatID(in url:URL)->String? {
        guard ["http","https"].contains(url.scheme?.lowercased() ?? ""),let host=url.host?.lowercased(),
              ["notion.so","notion.com"].contains(where:{host == $0 || host.hasSuffix("."+$0)}),
              let value=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "t"})?.value,
              let id=compact(value),id.count == 32,id.allSatisfy(\.isHexDigit) else{return nil}
        return id
    }

    // MARK: Tools
    public enum ToolAction:Equatable {case read,search,create,update,delete,generate,run,upload,other}
    /// Where a tool works and what it does, from names such as `connections.notion.loadPage` or `notion_search`.
    public static func tool(_ name:String)->(source:String,action:ToolAction) {
        var parts=name.split(separator:".").map(String.init)
        if parts.first == "connections" {parts.removeFirst()}
        let verb=parts.last ?? name
        var source=parts.count>1 ? parts.dropLast().joined(separator:"."):""
        let words=words(verb)
        if source.isEmpty,words.count>1,words.first != nil,["notion","slack","github","web","calendar"].contains(words[0]) {source=words[0]}
        let actions:[(ToolAction,Set<String>)]=[
            (.search,["search","grep","find"]),(.generate,["generate"]),(.upload,["upload"]),
            (.create,["create","add","insert","append"]),(.update,["update","edit","set","move","rename","replace"]),
            (.delete,["delete","remove","archive","trash"]),(.run,["terminal","run","exec","execute"]),
            (.read,["load","read","view","get","query","list","fetch","open"]),
        ]
        for (action,keys) in actions where words.contains(where:keys.contains) {return (source,action)}
        return (source,.other)
    }
    private static func words(_ text:String)->[String] {
        var words:[String]=[],word=""
        for character in text {
            if character == "_" || character == "-" || character == " " {if !word.isEmpty {words.append(word)};word="";continue}
            if character.isUppercase,!word.isEmpty {words.append(word);word=""}
            word.append(Character(character.lowercased()))
        }
        if !word.isEmpty {words.append(word)}
        return words
    }

    // MARK: Reply markup
    public enum Block:Equatable {
        case heading(level:Int,text:String)
        case paragraph(String)
        case item(level:Int,marker:String,text:String)
        case quote(String)
        case code(String)
        case table([[String]])
        /// Notion's cards: an edit the agent made (`edit`), a callout (`aside`), or a worker (`worker`).
        case note(kind:String,text:String)
        case rule
    }
    private static let mark="\u{1}"
    private static func regex(_ pattern:String,_ options:NSRegularExpression.Options=[])->NSRegularExpression {
        try! NSRegularExpression(pattern:pattern,options:options)
    }
    private static func replace(_ text:String,_ expression:NSRegularExpression,_ transform:([String])->String)->String {
        let source=text as NSString
        var result="",last=0
        for match in expression.matches(in:text,range:NSRange(location:0,length:source.length)) {
            result += source.substring(with:NSRange(location:last,length:match.range.location-last))
            let groups=(0..<match.numberOfRanges).map {match.range(at:$0).location == NSNotFound ? "":source.substring(with:match.range(at:$0))}
            result += transform(groups)
            last=match.range.location+match.range.length
        }
        return result+source.substring(from:last)
    }
    private static func attribute(_ name:String,in attributes:String)->String? {
        let found=replace(attributes,regex("^.*?\\b"+name+"=\"([^\"]*)\".*$",[.dotMatchesLineSeparators])) {$0[1]}
        return found == attributes ? nil:found
    }
    private static let cards=regex("<(edit_reference|aside|worker_reference)\\b([^>]*)>(.*?)</\\1>",[.dotMatchesLineSeparators])
    private static let mentions=regex("<(mention(?:-[a-z]+)?)\\b([^>]*?)(?:/>|>(.*?)</\\1>)",[.dotMatchesLineSeparators])
    private static let styles=regex("<(b|strong|i|em|s|del|code|u)>(.*?)</\\1>",[.dotMatchesLineSeparators])
    private static let leftovers=regex("<([a-z][a-z0-9_-]*)\\b[^<>]*>(.*?)</\\1>",[.dotMatchesLineSeparators])
    private static let citations=regex("\\[\\^([^\\]\\s]+)\\]")
    private static func link(_ label:String,_ url:String)->String {
        let safe=label.replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]")
        return "["+safe+"](<"+url+">)"
    }
    /// Inline Notion tags as Markdown: mentions become links and citations numbered links.
    static func inline(_ text:String,citing sources:inout [String])->String {
        var out=replace(text,mentions) {groups in
            let label=groups[3].trimmingCharacters(in:.whitespacesAndNewlines)
            guard let url=attribute("url",in:groups[2]),URL(string:url)?.scheme != nil else{return label}
            return link(label.isEmpty ? (groups[1] == "mention-page" ? L("ページ"):url):label,url)
        }
        out=replace(out,styles) {groups in
            switch groups[1] {
            case "b","strong":return "**"+groups[2]+"**"
            case "i","em":return "*"+groups[2]+"*"
            case "s","del":return "~~"+groups[2]+"~~"
            case "code":return "`"+groups[2]+"`"
            default:return groups[2]
            }
        }
        out=out.replacingOccurrences(of:"<br>",with:"\n").replacingOccurrences(of:"<br/>",with:"\n").replacingOccurrences(of:"<br />",with:"\n")
        for _ in 0..<3 {
            let next=replace(out,leftovers) {$0[2]}
            if next == out {break};out=next
        }
        var collected=sources
        out=replace(out,citations) {groups in
            let target=groups[1]
            guard let scheme=URL(string:target)?.scheme,!scheme.isEmpty else{return ""}
            if !collected.contains(target) {collected.append(target)}
            return link("["+String((collected.firstIndex(of:target) ?? 0)+1)+"]",target)
        }
        sources=collected
        // Markdown ignores ** right inside punctuation followed by a letter, as in **「強調」**です,
        // which Japanese replies write all the time; a zero-width space keeps it bold.
        let marks=CharacterSet.punctuationCharacters.union(.symbols)
        out=replace(out,strong) {groups in
            var inner=groups[1]
            if let first=inner.unicodeScalars.first,marks.contains(first) {inner="\u{200B}"+inner}
            if let last=inner.unicodeScalars.last,marks.contains(last) {inner+="\u{200B}"}
            return "**"+inner+"**"
        }
        return out
    }
    private static let strong=regex("\\*\\*([^*\\n]+?)\\*\\*")
    public static func blocks(_ raw:String)->[Block] {
        var text=raw.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:mark,with:"")
        text=replace(text,cards) {groups in
            let body=groups[1] == "worker_reference" ? (attribute("icon",in:groups[2]) ?? ""):groups[3]
            let line=body.split(whereSeparator:\.isNewline).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}.joined(separator:" ")
            return "\n"+mark+groups[1]+mark+line+"\n"
        }
        var blocks:[Block]=[],paragraph:[String]=[],quote:[String]=[],table:[[String]]=[],code:[String]?=nil,sources:[String]=[]
        func flush() {
            if !paragraph.isEmpty {blocks.append(.paragraph(inline(paragraph.joined(separator:"\n"),citing:&sources)))}
            if !quote.isEmpty {blocks.append(.quote(inline(quote.joined(separator:"\n"),citing:&sources)))}
            if !table.isEmpty {
                let width=table.map(\.count).max() ?? 0
                blocks.append(.table(table.map {row in (row+Array(repeating:"",count:width-row.count)).map{inline($0,citing:&sources)}}))
            }
            paragraph=[];quote=[];table=[]
        }
        let heading=regex("^(#{1,6})\\s+(.*)$"),rule=regex("^(-{3,}|\\*{3,}|_{3,})$"),item=regex("^([ \\t]*)([-*•‣◦]|\\d{1,3}[.)])\\s+(.*)$")
        func groups(_ expression:NSRegularExpression,_ line:String)->[String]? {
            let source=line as NSString
            guard let match=expression.firstMatch(in:line,range:NSRange(location:0,length:source.length)) else{return nil}
            return (0..<match.numberOfRanges).map {match.range(at:$0).location == NSNotFound ? "":source.substring(with:match.range(at:$0))}
        }
        for line in text.components(separatedBy:"\n") {
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            if var lines=code {
                if trimmed.hasPrefix("```") {blocks.append(.code(lines.joined(separator:"\n")));code=nil}
                else {lines.append(line);code=lines}
                continue
            }
            if trimmed.hasPrefix("```") {flush();code=[];continue}
            if trimmed.isEmpty {flush();continue}
            if trimmed.hasPrefix(mark) {
                flush()
                let parts=trimmed.dropFirst(mark.count).components(separatedBy:mark)
                let kind=parts.first ?? "",body=parts.dropFirst().joined()
                blocks.append(.note(kind:kind == "edit_reference" ? "edit":kind == "worker_reference" ? "worker":"aside",text:inline(body,citing:&sources)))
                continue
            }
            if let found=groups(heading,trimmed) {flush();blocks.append(.heading(level:found[1].count,text:inline(found[2],citing:&sources)));continue}
            if groups(rule,trimmed) != nil {flush();blocks.append(.rule);continue}
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty {let rows=table;table=[];flush();table=rows}
                var cells=trimmed.split(separator:"|",omittingEmptySubsequences:false).map{$0.trimmingCharacters(in:.whitespaces)}
                if cells.first == "" {cells.removeFirst()}
                if cells.last == "" {cells.removeLast()}
                if !cells.allSatisfy({$0.range(of:"^:?-{2,}:?$",options:.regularExpression) != nil}) {table.append(cells)}
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !table.isEmpty {let lines=quote;quote=[];flush();quote=lines}
                quote.append(trimmed.dropFirst().trimmingCharacters(in:.whitespaces));continue
            }
            if let found=groups(item,line) {
                flush()
                let indent=found[1].reduce(0){$0+($1 == "\t" ? 2:1)}
                let level=min(4,indent/2)
                var marker=found[2].first?.isNumber == true ? found[2].replacingOccurrences(of:")",with:"."):(level == 0 ? "•":"◦")
                var body=found[3]
                if body.hasPrefix("[ ] ") {marker="☐";body=String(body.dropFirst(4))}
                else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {marker="☑";body=String(body.dropFirst(4))}
                blocks.append(.item(level:level,marker:marker,text:inline(body,citing:&sources)))
                continue
            }
            if !quote.isEmpty || !table.isEmpty {let lines=paragraph;paragraph=[];flush();paragraph=lines}
            paragraph.append(trimmed)
        }
        if let lines=code {blocks.append(.code(lines.joined(separator:"\n")))}
        flush()
        return blocks
    }
}
