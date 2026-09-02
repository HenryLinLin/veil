pub fn version() -> &'static str {
    "0.1.0"
}

#[cfg(test)]
mod tests {
    #[test]
    fn has_version() {
        assert_eq!(super::version(), "0.1.0");
    }
}
