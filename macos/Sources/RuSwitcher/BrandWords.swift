import Foundation

/// Встроенный словарь брендов и IT-терминов как ЦЕЛЕЙ автоконверсии (issue #34).
///
/// Системный словарь их не знает, поэтому «срфепзе», набранное в русской раскладке,
/// не становилось «chatgpt»: цель не подтверждена словарём. Список только подтверждает
/// цель (Dict.isValidTarget) и не обходит проверку набранного: правильно набранное
/// русское слово по-прежнему остаётся как есть.
///
/// Только латиница и не короче четырёх букв. Трёхбуквенные аббревиатуры не берём: их
/// русские образы бывают настоящими сокращениями («мгу» → «vue»), а набранные заглавными
/// (API, CRM) детектор и так не трогает. Проверено замером: правильно набранные бренды
/// из этого списка автоконверсия не трогает, как и раньше.
enum BrandWords {
    static let all: Set<String> = [
        // ИИ
        "chatgpt", "openai", "anthropic", "claude", "gemini", "copilot", "midjourney", "perplexity",
        "ollama", "llama", "mistral", "deepseek", "qwen", "grok", "dalle", "sora", "huggingface",
        "langchain", "kandinsky", "gigachat", "yandexgpt", "cursor", "windsurf", "cline", "aider",
        "codex", "devin", "tabnine", "lovable", "replit", "openrouter", "stablediffusion",
        // разработка
        "github", "gitlab", "bitbucket", "docker", "kubernetes", "terraform", "ansible", "nginx",
        "redis", "postgres", "postgresql", "mysql", "mongodb", "kafka", "nextjs", "nodejs", "pnpm",
        "webpack", "vite", "django", "flask", "fastapi", "golang", "kotlin", "typescript",
        "javascript", "laravel", "symfony", "bitrix", "wordpress", "vscode", "xcode", "jetbrains",
        "intellij", "pycharm", "webstorm", "goland", "postman", "figma", "miro", "jira", "confluence",
        "notion", "trello", "asana", "clickup", "airtable", "zapier", "supabase", "firebase",
        "vercel", "netlify", "heroku", "cloudflare", "devops", "mlops", "hotfix", "fullstack",
        "teamlead", "vibecoding", "finetune", "frontend", "backend", "localhost",
        // сервисы и устройства
        "telegram", "whatsapp", "viber", "discord", "youtube", "tiktok", "instagram", "facebook",
        "twitter", "reddit", "habr", "ozon", "wildberries", "avito", "yandex", "google", "iphone",
        "ipad", "macbook", "imac", "macos", "ipados", "watchos", "airpods", "android", "samsung",
        "xiaomi", "huawei", "ubuntu", "debian", "fedora", "firefox", "chrome", "safari", "spotify",
        "netflix", "skype", "steam", "twitch", "linkedin", "pinterest", "dropbox", "gmail",
        "outlook", "powerpoint", "excel", "onedrive", "icloud", "appstore", "playstation", "xbox",
        "nintendo", "tesla", "nvidia", "intel", "raspberry", "arduino", "homebrew",
    ]
}
