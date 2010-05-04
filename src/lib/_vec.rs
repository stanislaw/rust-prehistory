import vbuf = rustrt.vbuf;

native "rust" mod rustrt {
  type vbuf;
  fn vec_buf[T](vec[T] v) -> vbuf;
  fn vec_len[T](vec[T] v) -> uint;
  fn vec_alloc[T](int n_elts) -> vec[T];
}

fn alloc[T](int n_elts) -> vec[T] {
  ret rustrt.vec_alloc[T](n_elts);
}

fn len[T](vec[T] v) -> uint {
  ret rustrt.vec_len[T](v);
}

fn buf[T](vec[T] v) -> vbuf {
  ret rustrt.vec_buf[T](v);
}
