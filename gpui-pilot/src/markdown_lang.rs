//! Markdown as Zed highlights it, for editors where people write it (notes):
//! Zed's tree-sitter grammar and its own highlight queries, from its
//! `grammars` crate. Two languages, because inline text (emphasis, code,
//! links) is a second grammar the block one injects; both have to be in
//! the buffer's registry for the inline layer to colour. The colours are
//! the active theme's syntax colours (`zed.rs`).

use gpui::{App, Entity, Global};
use language::{Buffer, Language, LanguageRegistry};
use std::sync::Arc;

struct Markdown {
    registry: Arc<LanguageRegistry>,
    language: Arc<Language>,
}

impl Global for Markdown {}

fn queried(language: Language, name: &str) -> Option<Arc<Language>> {
    language.with_queries(grammars::load_queries(name)).ok().map(Arc::new)
}

/// Built once: the registry with both languages, and the block one.
fn markdown(cx: &mut App) -> Option<(Arc<LanguageRegistry>, Arc<Language>)> {
    if let Some(m) = cx.try_global::<Markdown>() {
        return Some((m.registry.clone(), m.language.clone()));
    }
    let block = queried(Language::new(grammars::load_config("markdown"), Some(tree_sitter_md::LANGUAGE.into())), "markdown")?;
    let inline = queried(Language::new(grammars::load_config("markdown-inline"), Some(tree_sitter_md::INLINE_LANGUAGE.into())), "markdown-inline")?;
    let registry = Arc::new(LanguageRegistry::new(cx.background_executor().clone()));
    registry.add(block.clone());
    registry.add(inline);
    cx.set_global(Markdown { registry: registry.clone(), language: block.clone() });
    Some((registry, block))
}

/// Highlights `buffer` as markdown; leaves it plain if the grammar won't load.
pub fn highlight(buffer: &Entity<Buffer>, cx: &mut App) {
    let Some((registry, language)) = markdown(cx) else { return };
    buffer.update(cx, |buffer, cx| {
        buffer.set_language_registry(registry);
        buffer.set_language(Some(language), cx);
    });
}
