declare module "qrcode-terminal" { const q: { generate(text: string, opts?: { small?: boolean }, cb?: (s: string) => void): void }; export default q; }
