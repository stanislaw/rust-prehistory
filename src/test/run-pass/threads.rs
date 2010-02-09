// -*- C -*-

fn main() -> () {
  let port[int] p = port();
  let int i = 1000;
  while (i > 0) {
    spawn thread child(i);
    i = i - 1;
  }
  log "main thread exiting";
}

fn child(int x) -> () {
  log x;
}

