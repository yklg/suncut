import Foundation

/// DashScope cosyvoice-v2 系统音色目录（仅普通话子集；广告/带货人设排前 10）。
/// 顶部「配音设置」默认展示 `all.prefix(10)`，其余供后续搜索/全列表扩展。
public enum CosyVoiceCatalog {
    /// 适配 cosyvoice-v2 的模型标识。
    public static let model = "cosyvoice-v2"

    public static let all: [TTSVoice] = [
        // —— 前 10：信息流广告/带货人设（带 .commerce，选择器「带货人设」chip 命中此集） ——
        TTSVoice(id: "longyingxiao", displayName: "龙樱晓", summary: "甜美带货女主播，亲和有感染力", tags: [.female, .commerce]),
        TTSVoice(id: "longanchong", displayName: "龙安宠", summary: "激情四射的带货销售男", tags: [.male, .commerce]),
        TTSVoice(id: "longanxuan", displayName: "龙安璇", summary: "经典女主播，专业稳定", tags: [.female, .commerce]),
        TTSVoice(id: "longanping", displayName: "龙安萍", summary: "高音直播女，热场带节奏", tags: [.female, .commerce]),
        TTSVoice(id: "longxiaochun_v2", displayName: "龙小淳", summary: "知性积极女，干净自然", tags: [.female, .commerce]),
        TTSVoice(id: "longanrou", displayName: "龙安柔", summary: "温柔闺蜜女，贴心种草", tags: [.female, .commerce]),
        TTSVoice(id: "longanyun", displayName: "龙安耘", summary: "居家暖心男，亲切可信", tags: [.male, .commerce]),
        TTSVoice(id: "longyichen", displayName: "龙逸尘", summary: "洒脱活力男，年轻有冲劲", tags: [.male, .commerce]),
        TTSVoice(id: "longhua_v2", displayName: "龙华", summary: "活力甜美女，元气满满", tags: [.female, .commerce]),
        TTSVoice(id: "longanlang", displayName: "龙安朗", summary: "清新干净男，清爽利落", tags: [.male, .commerce]),

        // —— 其余普通话音色（性别类按 summary 原文逐条标注，恰一；现实老人/僧俗归男女声）——
        TTSVoice(id: "longanli", displayName: "龙安丽", summary: "清脆沉稳女", tags: [.female]),
        TTSVoice(id: "longanwen", displayName: "龙安雯", summary: "优雅知性女", tags: [.female]),
        TTSVoice(id: "longanqin", displayName: "龙安琴", summary: "亲和活泼女", tags: [.female]),
        TTSVoice(id: "longanya", displayName: "龙安雅", summary: "优雅高贵女", tags: [.female]),
        TTSVoice(id: "longanling", displayName: "龙安灵", summary: "思维敏捷女", tags: [.female]),
        TTSVoice(id: "longanran", displayName: "龙安然", summary: "活泼有质感女", tags: [.female]),
        TTSVoice(id: "longanshuo", displayName: "龙安朔", summary: "干净清爽男", tags: [.male]),
        TTSVoice(id: "longanzhi", displayName: "龙安之", summary: "睿智成熟青年男", tags: [.male]),
        TTSVoice(id: "longyumi_v2", displayName: "YUMI", summary: "严肃年轻女", tags: [.female]),
        TTSVoice(id: "longxiaoxia_v2", displayName: "龙小夏", summary: "沉稳权威女", tags: [.female]),
        TTSVoice(id: "longwanjun", displayName: "龙婉君", summary: "细腻轻柔女", tags: [.female]),
        TTSVoice(id: "longbaizhi", displayName: "龙白芷", summary: "睿智旁白女", tags: [.female]),
        TTSVoice(id: "longmiao_v2", displayName: "龙淼", summary: "抑扬顿挫女", tags: [.female]),
        TTSVoice(id: "longyue_v2", displayName: "龙玥", summary: "温暖磁性女", tags: [.female]),
        TTSVoice(id: "longyuan_v2", displayName: "龙媛", summary: "温暖治愈女", tags: [.female]),
        TTSVoice(id: "longxing_v2", displayName: "龙馨", summary: "邻家温柔女", tags: [.female]),
        TTSVoice(id: "longwan_v2", displayName: "龙菀", summary: "积极知性女", tags: [.female]),
        TTSVoice(id: "longfeifei_v2", displayName: "龙菲菲", summary: "甜美细腻女", tags: [.female]),
        TTSVoice(id: "longyan_v2", displayName: "龙嫣", summary: "温暖柔和女", tags: [.female]),
        TTSVoice(id: "longqiang_v2", displayName: "龙嫱", summary: "浪漫魅力女", tags: [.female]),
        TTSVoice(id: "loongbella_v2", displayName: "Bella 2.0", summary: "精准干练女", tags: [.female]),
        TTSVoice(id: "loongstella_v2", displayName: "Stella", summary: "清脆高效女", tags: [.female]),
        TTSVoice(id: "longxiaobai_v2", displayName: "龙小白", summary: "沉稳播音女", tags: [.female]),
        TTSVoice(id: "longjing_v2", displayName: "龙婧", summary: "标准女主播", tags: [.female]),
        TTSVoice(id: "longnan_v2", displayName: "龙楠", summary: "睿智青年男", tags: [.male]),
        TTSVoice(id: "longcheng_v2", displayName: "龙澄", summary: "睿智青年男", tags: [.male]),
        TTSVoice(id: "longhan_v2", displayName: "龙翰", summary: "温暖深情男", tags: [.male]),
        TTSVoice(id: "longxiaocheng_v2", displayName: "龙小诚", summary: "磁性低音男", tags: [.male]),
        TTSVoice(id: "longzhe_v2", displayName: "龙喆", summary: "冷面暖心男", tags: [.male]),
        TTSVoice(id: "longtian_v2", displayName: "龙天", summary: "磁性理性男", tags: [.male]),
        TTSVoice(id: "longze_v2", displayName: "龙泽", summary: "温暖活力男", tags: [.male]),
        TTSVoice(id: "longshao_v2", displayName: "龙韶", summary: "积极向上男", tags: [.male]),
        TTSVoice(id: "longhao_v2", displayName: "龙昊", summary: "深情忧郁男", tags: [.male]),
        TTSVoice(id: "longfei_v2", displayName: "龙飞", summary: "热情磁性男", tags: [.male]),
        TTSVoice(id: "longjin_v2", displayName: "龙瑾", summary: "优雅温和男", tags: [.male]),
        TTSVoice(id: "longshu_v2", displayName: "龙澍", summary: "沉稳青年男", tags: [.male]),
        TTSVoice(id: "longshuo_v2", displayName: "龙烁", summary: "博学干练男", tags: [.male]),
        TTSVoice(id: "longsanshu", displayName: "龙三叔", summary: "沉稳儒雅男", tags: [.male]),
        TTSVoice(id: "longxiu_v2", displayName: "龙修", summary: "博学说书男", tags: [.male]),
        TTSVoice(id: "longanpei", displayName: "龙安佩", summary: "年轻教师女", tags: [.female]),
        TTSVoice(id: "longhuhu", displayName: "龙呼呼", summary: "天真活泼女孩", tags: [.child]),
        TTSVoice(id: "longniuniu", displayName: "龙妞妞", summary: "阳光男孩", tags: [.child]),
        TTSVoice(id: "longke_v2", displayName: "龙可", summary: "天真乖巧女孩", tags: [.child]),
        TTSVoice(id: "longxian_v2", displayName: "龙娴", summary: "大胆可爱女", tags: [.female]),
        TTSVoice(id: "longling_v2", displayName: "龙铃", summary: "童稚冷面女", tags: [.child]),
        TTSVoice(id: "longjielidou_v2", displayName: "龙杰力豆", summary: "阳光顽皮男孩", tags: [.child]),
        TTSVoice(id: "longlaobo", displayName: "龙老伯", summary: "沧桑老者男", tags: [.male]),
        TTSVoice(id: "longlaoyi", displayName: "龙老姨", summary: "世故阿姨女", tags: [.female]),
        TTSVoice(id: "longgaoseng", displayName: "龙高僧", summary: "得道高僧男", tags: [.male]),
        TTSVoice(id: "longdaiyu", displayName: "龙黛玉", summary: "灵秀才女", tags: [.female]),
        TTSVoice(id: "longjixin", displayName: "龙吉心", summary: "毒舌伶俐女", tags: [.female]),
        TTSVoice(id: "longjiqi", displayName: "龙吉奇", summary: "萌呆机器人男", tags: [.character]),
        TTSVoice(id: "longhouge", displayName: "龙猴哥", summary: "经典美猴王男", tags: [.character]),
        TTSVoice(id: "libai_v2", displayName: "李白", summary: "古风诗人男", tags: [.character]),
        TTSVoice(id: "kabuleshen_v2", displayName: "龙神", summary: "才华歌手男", tags: [.character]),
        TTSVoice(id: "longshanshan", displayName: "龙闪闪", summary: "戏剧童声女", tags: [.child]),
        TTSVoice(id: "longyingmu", displayName: "龙樱木", summary: "优雅知性女", tags: [.female]),
        TTSVoice(id: "longyingda", displayName: "龙樱达", summary: "开朗高音女", tags: [.female]),
        TTSVoice(id: "longyingtian", displayName: "龙樱恬", summary: "温柔甜美女", tags: [.female]),
        TTSVoice(id: "longyingtao", displayName: "龙樱桃", summary: "温柔沉稳女", tags: [.female]),
        TTSVoice(id: "longyingling", displayName: "龙樱铃", summary: "温柔共情女", tags: [.female]),
        TTSVoice(id: "longyingjing", displayName: "龙樱静", summary: "低调沉稳女", tags: [.female]),
        TTSVoice(id: "longyingyan", displayName: "龙樱岩", summary: "正气严厉女", tags: [.female]),
        TTSVoice(id: "longyingbing", displayName: "龙樱冰", summary: "犀利果断女", tags: [.female]),
        TTSVoice(id: "longyingxun", displayName: "龙樱勋", summary: "青涩年轻男", tags: [.male]),
        TTSVoice(id: "longyingcui", displayName: "龙樱崔", summary: "严肃催收男", tags: [.male]),
    ]
}

/// 当前生效的 TTS 音色目录与查询入口（现为 CosyVoice）。
/// 视图/VM 一律走这里，换模型时只改这一处。
public enum VoiceCatalog {
    /// 当前生效目录（全部音色）。
    public static var active: [TTSVoice] { CosyVoiceCatalog.all }

    /// 顶部默认展示的前若干音色。
    public static func top(_ n: Int) -> [TTSVoice] { Array(active.prefix(n)) }

    /// 按 voiceId 查音色（找不到返回 nil）。
    public static func voice(id: String) -> TTSVoice? {
        active.first { $0.id == id }
    }

    /// 按 voiceId 查显示名（找不到回退原 id）。
    public static func displayName(id: String) -> String {
        voice(id: id)?.displayName ?? id
    }
}
