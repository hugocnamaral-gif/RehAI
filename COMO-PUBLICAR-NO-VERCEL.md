# Publicar no Vercel — o que fazer

## O problema, numa frase

O `vercel.json` mandava correr `node web/build.js`, e **esse ficheiro não existe
no repositório** que o Vercel publica. O build falhava (o X vermelho em
*Deployments → Production*) e o site continuava a servir a versão anterior.

O sintoma engana: o `index.html` está certo, o upload funciona, e o site não muda.

---

## O que substituir

### 1. `vercel.json` — **este é o que está errado**

Sobe este ficheiro para a **raiz do repositório**, por cima do que lá está:

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": null,
  "cleanUrls": true,
  "trailingSlash": false,
  "headers": [
    {
      "source": "/",
      "headers": [{ "key": "Cache-Control", "value": "no-store, must-revalidate" }]
    },
    {
      "source": "/index.html",
      "headers": [{ "key": "Cache-Control", "value": "no-store, must-revalidate" }]
    },
    {
      "source": "/(.*)",
      "headers": [
        { "key": "X-Content-Type-Options", "value": "nosniff" },
        { "key": "X-Frame-Options", "value": "DENY" },
        { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" },
        { "key": "Permissions-Policy", "value": "geolocation=(), microphone=(), camera=()" },
        { "key": "Strict-Transport-Security", "value": "max-age=63072000; includeSubDomains" }
      ]
    }
  ]
}
```

**O que saiu, e porquê:**

| Linha que saiu | Porque estava a partir o build |
|---|---|
| `"buildCommand": "node web/build.js"` | O `web/build.js` não existe no repositório. O Vercel tentava correr e falhava. |
| `"outputDirectory": "web/dist"` | Essa pasta também não existe. O Vercel procurava o `index.html` no sítio errado. |
| `"installCommand": "echo ..."` | Não há dependências para instalar. Era ruído. |

O `index.html` está na raiz do repositório. **Sem `buildCommand` e sem
`outputDirectory`, o Vercel serve-o diretamente** — que é o que se quer: é um
programa de um ficheiro só.

### 2. `index.html` — **já está certo, mas confirma a versão**

O que está no repositório tem de ser o `publicar/index.html` que te dei.

Para confirmar sem abrir o browser: abre o `index.html` num editor e procura
`C.VERSAO`. Tem de dizer:

```
2026-10-14 21:17
```

Se disser `13:44`, é o antigo e o problema é o upload, não o Vercel.

---

## Depois de subir

1. Vai a **Deployments** no painel do Vercel.
2. O upload de um ficheiro dispara um deployment novo sozinho.
3. **Vê o estado.** Tem de ficar **Ready** (verde) e não **Error** (vermelho).
4. Abre o site e faz **Ctrl+Shift+R**.

---

## Como saber se resultou, sem depender do browser

Cola isto na consola do browser (F12 → Console), **no site**:

```js
document.documentElement.innerHTML.match(/C\.VERSAO\s*=\s*'([^']+)'/)[1]
```

- Diz `2026-10-14 21:17` → **está publicado.** O problema acabou.
- Diz `2026-10-14 13:44` → o site ainda serve o antigo. Vê o estado do deployment
  no Vercel: se estiver vermelho, o erro do build diz o que falta.
- Dá erro → estás a correr a consola numa página que não é a aplicação.

---

## Porque é que isto passou despercebido tanto tempo

O `vercel.json` com `buildCommand` fazia sentido **quando o repositório tinha o
projeto inteiro** (com `web/build.js`, `db/`, `tools/`). Nessa altura o Vercel
construía o ficheiro a partir do código-fonte.

Depois passou-se a subir **só o `index.html` já construído** — que é mais simples
e não precisa de build nenhum. Mas o `vercel.json` ficou como estava, e passou a
apontar para ficheiros que já não vão no repositório.

**Um ficheiro de configuração que descreve um repositório que já não existe é uma
armadilha:** o erro aparece no Vercel, longe de quem mexe no `index.html`.
