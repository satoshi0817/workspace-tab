import Foundation

/// Display identity only. Never persisted with tabs, exported, or used as a credential.
public struct NotionAccount:Equatable {
    public let id:String
    public let name:String
    public let email:String
    /// Encoded profile photo bytes, when Notion served one. Memory only.
    public let avatar:Data?
    public var displayName:String {name.isEmpty ? email:name}
    public static func decode(_ value:[String:Any],matching userID:String)->NotionAccount? {
        guard let expected=NotionWorkspace.normalizedID(userID),
              let id=NotionWorkspace.normalizedID(value["id"] as? String),id == expected,
              let email=(value["email"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines),
              email.count<=320,email.range(of:#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,options:.regularExpression) != nil,
              !email.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{return nil}
        let name=(value["name"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard name.count<=160,!name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{return nil}
        let avatar=(value["avatar"] as? String).flatMap {$0.count<=420_000 ? Data(base64Encoded:$0):nil}
        return NotionAccount(id:id,name:name,email:email,avatar:avatar)
    }
    private static let helpers = #"""
    const allowed = () => location.protocol === 'https:' && ['app.notion.com','app.dev.notion.com','notion.so','www.notion.so'].includes(location.hostname);
    const compact = value => typeof value === 'string' && /^[a-f0-9]{32}$/i.test(value.replace(/-/g,'')) ? value.replace(/-/g,'').toLowerCase() : null;
    const perTab = () => {try {return compact(sessionStorage.getItem('activeUserId'));} catch (_) {return null;}};
    const read = key => {try {return JSON.parse(localStorage.getItem('LRU:KeyValueStore2:' + key) || 'null')?.value;} catch (_) {return null;}};
    // The user Notion recorded for the page this tab is showing. Only trusted when the
    // recorded route is exactly this URL's page, because the entry is shared by all tabs.
    const routeUser = () => {
      const route = read('lastVisitedRoute');
      const last = location.pathname.split('/').filter(Boolean).pop() || '';
      const page = last.match(/([a-f0-9]{32}|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/i)?.[1];
      if (!page || route?.name !== 'page' || compact(route.blockId) !== compact(page)) return null;
      return compact(read('lastVisitedRouteUserId'));
    };
    const current = () => compact(read('current-user-id'));
    const active = () => routeUser() ?? perTab() ?? current();
    """#
    /// Runs before Notion boots in a new tab so it starts as the chosen account.
    /// Seeds once per tab; later account switches inside Notion are left alone.
    public static func seedScript(_ userID:String)->String? {
        guard let id=NotionWorkspace.normalizedID(userID) else{return nil}
        let c=Array(id),dashed=[c[0..<8],c[8..<12],c[12..<16],c[16..<20],c[20..<32]].map{String($0)}.joined(separator:"-")
        return """
        (()=>{try{
          if(location.protocol!=='https:'||!['app.notion.com','app.dev.notion.com','notion.so','www.notion.so'].includes(location.hostname))return;
          if(sessionStorage.getItem('workspaceTabsAccountSeed'))return;
          sessionStorage.setItem('workspaceTabsAccountSeed','1');sessionStorage.setItem('activeUserId','\(dashed)');
        }catch(_){}})()
        """
    }
    /// User IDs from Notion's own list of signed-in accounts (the notion_users cookie).
    public static func userIDs(fromCookie value:String)->[String] {
        guard let data=(value.removingPercentEncoding ?? value).data(using:.utf8),
              let list=try? JSONSerialization.jsonObject(with:data) as? [Any] else{return []}
        var seen=Set<String>()
        return Array(list.compactMap{NotionWorkspace.normalizedID($0 as? String)}.filter{seen.insert($0).inserted}.prefix(8))
    }
    /// Name and email for each signed-in account, for the account chooser. Display only.
    public static let directoryScript = helpers + #"""
    if (!allowed() || !Array.isArray(ids)) return [];
    const abort = new AbortController();
    const timeout = setTimeout(() => abort.abort(), 4000);
    try {
      return (await Promise.all(ids.slice(0, 8).map(async raw => {
        const userID = compact(raw);
        if (!userID) return null;
        const dashed = userID.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
        try {
          const response = await fetch('/api/v3/syncRecordValues', {
            method:'POST',credentials:'same-origin',mode:'same-origin',redirect:'error',cache:'no-store',signal:abort.signal,
            headers:{'content-type':'application/json','x-notion-active-user-header':dashed},
            body:JSON.stringify({requests:[{pointer:{table:'notion_user',id:dashed},version:-1}]})
          });
          if (!response.ok) return null;
          const users = (await response.json())?.recordMap?.notion_user;
          const entry = users?.[dashed] ?? users?.[userID];
          if (!entry || entry.role === 'none' || entry.value?.role === 'none') return null;
          const record = entry.value?.value ?? entry.value;
          if (compact(record?.id) !== userID || typeof record.email !== 'string') return null;
          const name = typeof record.name === 'string' ? record.name : [record.given_name,record.family_name].filter(v => typeof v === 'string').join(' ');
          return {id:userID,name,email:record.email};
        } catch (_) {return null;}
      }))).filter(Boolean);
    } finally {clearTimeout(timeout);}
    """#
    // Order: the user Notion recorded for this exact page, then the tab's own choice in
    // sessionStorage, then Notion's current-user entry. Workspace IDs and saved account
    // notes are not substitutes.
    public static let probeScript = helpers + #"""
    if (!allowed()) return null;
    return {url:location.href,userID:active()};
    """#
    public static let fetchScript = helpers + #"""
    if (!allowed() || location.href !== expectedURL || active() !== userID) return null;
    const dashed = userID.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
    const abort = new AbortController();
    const timeout = setTimeout(() => abort.abort(), 6000);
    try {
      const response = await fetch('/api/v3/syncRecordValues', {
        method:'POST',credentials:'same-origin',mode:'same-origin',redirect:'error',cache:'no-store',signal:abort.signal,
        headers:{'content-type':'application/json','x-notion-active-user-header':dashed},
        body:JSON.stringify({requests:[{pointer:{table:'notion_user',id:dashed},version:-1}]})
      });
      if (!response.ok) return null;
      const data = await response.json();
      if (!allowed() || location.href !== expectedURL || active() !== userID) return null;
      const users = data?.recordMap?.notion_user;
      const entry = users?.[dashed] ?? users?.[userID];
      if (!entry || entry.role === 'none' || entry.value?.role === 'none') return null;
      const record = entry.value?.value ?? entry.value;
      if (compact(record?.id) !== userID || typeof record.email !== 'string') return null;
      const name = typeof record.name === 'string' ? record.name : [record.given_name,record.family_name].filter(v => typeof v === 'string').join(' ');
      // Profile photo is optional. Only Notion's own same-origin image proxy is asked,
      // so the photo host never sees a request from this app.
      let avatar = null;
      const photo = record.profile_photo;
      if (typeof photo === 'string' && photo.length <= 2048 && /^(https:\/\/|attachment:|\/(?!\/))/.test(photo)) {
        try {
          const source = photo.startsWith('/') ? photo : '/image/' + encodeURIComponent(photo) + '?table=notion_user&id=' + dashed + '&userId=' + dashed + '&width=96&cache=v2';
          const image = await fetch(source, {credentials:'same-origin',signal:abort.signal});
          const blob = image.ok ? await image.blob() : null;
          if (blob && blob.size > 0 && blob.size <= 300000 && /^image\/(png|jpeg|gif|webp)$/.test(blob.type)) {
            const bytes = new Uint8Array(await blob.arrayBuffer());
            let binary = '';
            for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
            avatar = btoa(binary);
          }
        } catch (_) {avatar = null;}
        if (!allowed() || location.href !== expectedURL || active() !== userID) return null;
      }
      // Only these display fields leave the page. Do not forward the record map.
      return {url:expectedURL,userID,account:{id:userID,name,email:record.email,avatar}};
    } catch (_) {return null;}
    finally {clearTimeout(timeout);}
    """#
}
