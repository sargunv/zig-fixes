extern fn short_fn() c_int;
extern fn long_fn() c_int;

pub fn main() u8 {
    return if (short_fn() + long_fn() == 21) 0 else 1;
}
