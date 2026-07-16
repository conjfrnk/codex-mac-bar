/// Returns true for controls, noncharacters, Unicode format controls, and
/// default-ignorable scalars. Removing these before matching prevents invisible
/// characters from splitting credential keys; using the same predicate for UI
/// data keeps availability selection aligned with what can actually be shown.
pub(crate) fn is_unsafe_format_character(character: char) -> bool {
    let scalar = character as u32;
    character.is_control()
        || (0xfdd0..=0xfdef).contains(&scalar)
        || scalar & 0xffff >= 0xfffe
        || matches!(
            scalar,
            0x00ad
                | 0x034f
                | 0x0600..=0x0605
                | 0x061c
                | 0x06dd
                | 0x070f
                | 0x0890..=0x0891
                | 0x08e2
                | 0x115f..=0x1160
                | 0x17b4..=0x17b5
                | 0x180b..=0x180f
                | 0x200b..=0x200f
                | 0x202a..=0x202e
                | 0x2060..=0x206f
                | 0x3164
                | 0xfe00..=0xfe0f
                | 0xfeff
                | 0xffa0
                | 0xfff0..=0xfffb
                | 0x110bd
                | 0x110cd
                | 0x13430..=0x13455
                | 0x1bca0..=0x1bca3
                | 0x1d173..=0x1d17a
                | 0xe0000..=0xe0fff
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_format_and_default_ignorable_edge_classes() {
        for character in [
            '\u{00ad}',
            '\u{034f}',
            '\u{0600}',
            '\u{180e}',
            '\u{200b}',
            '\u{fe0f}',
            '\u{e0100}',
        ] {
            assert!(
                is_unsafe_format_character(character),
                "U+{:04X}",
                character as u32
            );
        }
        for character in ['A', 'é', '🦀'] {
            assert!(!is_unsafe_format_character(character));
        }
    }
}
