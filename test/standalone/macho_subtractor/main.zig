//! A pointer-sized `sym - .` difference is a link-time constant and must get
//! neither a rebase nor a weak bind, even when it sits in `__TEXT,__text`.

extern fn get_extsym() u64;
extern fn get_weaksym() u64;

pub fn main() u8 {
    if (get_extsym() != 0x1234) return 1;
    if (get_weaksym() != 0x5678) return 2;
    return 0;
}
