//! A bounded protobuf wire reader: just enough for the two game responses
//! the app reads.

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct FormatError(pub &'static str);

pub enum Field<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Fixed,
}

pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn varint(&mut self) -> Result<u64, FormatError> {
        let mut value = 0u64;
        for shift in (0..64).step_by(7) {
            let byte = *self.data.get(self.pos).ok_or(FormatError("truncated"))?;
            self.pos += 1;
            value |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return Ok(value);
            }
        }
        Err(FormatError("varint"))
    }

    /// The next field number and value; None at the end.
    pub fn next(&mut self) -> Result<Option<(u64, Field<'a>)>, FormatError> {
        if self.pos >= self.data.len() {
            return Ok(None);
        }
        let tag = self.varint()?;
        let number = tag >> 3;
        if number == 0 {
            return Err(FormatError("field"));
        }
        let field = match tag & 7 {
            0 => Field::Varint(self.varint()?),
            1 | 5 => {
                let size = if tag & 7 == 1 { 8 } else { 4 };
                if self.pos + size > self.data.len() {
                    return Err(FormatError("truncated"));
                }
                self.pos += size;
                Field::Fixed
            }
            2 => {
                let size = usize::try_from(self.varint()?).map_err(|_| FormatError("truncated"))?;
                let end = self.pos.checked_add(size).filter(|&e| e <= self.data.len()).ok_or(FormatError("truncated"))?;
                let bytes = &self.data[self.pos..end];
                self.pos = end;
                Field::Bytes(bytes)
            }
            _ => return Err(FormatError("wire_type")),
        };
        Ok(Some((number, field)))
    }
}
