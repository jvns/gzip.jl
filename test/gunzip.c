#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <assert.h>

// header separated from main struct for the "sizeof" below
typedef struct
{
  unsigned char id[ 2 ];
  unsigned char compression_method;
  unsigned char flags;
  unsigned char mtime[ 4 ];
  unsigned char extra_flags;
  unsigned char os;
}
gzip_header;

typedef struct
{
  gzip_header header;
  unsigned short xlen;
  unsigned char *extra;
  unsigned char *fname;
  unsigned char *fcomment;
  unsigned short crc16; // this protects the header
  unsigned long crc32;  // this protects the document
  unsigned long isize;
}
gzip_file;

#define FTEXT     0x01
#define FHCRC     0x02
#define FEXTRA    0x04
#define FNAME     0x08
#define FCOMMENT  0x10

typedef struct
{
  unsigned int len;
  unsigned int code;
} 
tree_node;

typedef struct huffman_node_t
{
  int code; // -1 for non-leaf nodes
  struct huffman_node_t *zero;
  struct huffman_node_t *one;
}
huffman_node;

typedef struct
{
  int end;
  int bit_length;
}
huffman_range;

static void build_huffman_tree( huffman_node *root,
                                int range_len,
                                huffman_range *range )
{
  int *bl_count;
  int *next_code;
  tree_node *tree;

  int bits;
  int code = 0;
  int n;
  int active_range;
  int max_bit_length;

  // step 1 - figure out how long bl_count, next_code, tree etc.
  // should be based on the ranges provided;
  max_bit_length = 0;
  for ( n = 0; n < range_len; n++ )
  {
    if ( range[ n ].bit_length > max_bit_length )
    {
      max_bit_length = range[ n ].bit_length;
    }
  }
  bl_count = malloc( sizeof( int ) * ( max_bit_length + 1 ) );
  next_code = malloc( sizeof( int ) * ( max_bit_length + 1 ) );
  tree = malloc( sizeof( tree_node ) * ( range[ range_len - 1 ].end + 1 ) );

  memset( bl_count, '\0', sizeof( int ) * ( max_bit_length + 1 ) );

  for ( n = 0; n < range_len; n++ )
  {
    bl_count[ range[ n ].bit_length ] += 
      range[ n ].end - ( ( n > 0 ) ? range[ n - 1 ].end : -1 );
  }

  // step 2, directly from RFC
  memset( next_code, '\0', sizeof( int ) * ( max_bit_length + 1 ) );
  for ( bits = 1; bits <= max_bit_length; bits++ )
  {
    code = ( code + bl_count[ bits - 1 ] ) << 1;
    if ( bl_count[ bits ] )
    {
      next_code[ bits ] = code;
    }
  }

  // step 3, directly from RFC
  memset( tree, '\0', sizeof( tree_node ) * 
    ( range[ range_len - 1 ].end + 1 ) );
  active_range = 0;
  for ( n = 0; n <= range[ range_len - 1 ].end; n++ )
  {
    if ( n > range[ active_range ].end )
    {
      active_range++;
    }

    if ( range[ active_range ].bit_length )
    {
      tree[ n ].len = range[ active_range ].bit_length;

      if ( tree[ n ].len != 0 )
      {
        tree[ n ].code = next_code[ tree[ n ].len ];
        next_code[ tree[ n ].len ]++;
      }
    }
  }

  // Ok, now I have the codes... convert them into a traversable 
  // huffman tree
  root->code = -1;
  for ( n = 0; n <= range[ range_len - 1 ].end; n++ )
  {
    huffman_node *node;
    node = root;
    if ( tree[ n ].len )
    {
      for ( bits = tree[ n ].len; bits; bits-- )
      {
        if ( tree[ n ].code & ( 1 << ( bits - 1 ) ) )
        {
          if ( !node->one )
          {
            node->one = ( struct huffman_node_t * ) 
              malloc( sizeof( huffman_node ) );
            memset( node->one, '\0', sizeof( huffman_node ) );
            node->one->code = -1;
          }
          node = ( huffman_node * ) node->one;
        }
        else
        {
          if ( !node->zero )
          {
            node->zero = ( struct huffman_node_t * ) 
              malloc( sizeof( huffman_node ) );
            memset( node->zero, '\0', sizeof( huffman_node ) );
            node->zero->code = -1;
          }
          node = ( huffman_node * ) node->zero;
        }
      }
      assert( node->code == -1 );
      node->code = n;
    }
  }

  free( bl_count );
  free( next_code );
  free( tree );
}

/** 
 * Build a Huffman tree for the following values:
 *   0 - 143: 00110000  - 10111111     (8)
 * 144 - 255: 110010000 - 111111111    (9)
 * 256 - 279: 0000000   - 0010111      (7)
 * 280 - 287: 11000000  - 11000111     (8)
 * According to the RFC 1951 rules in section 3.2.2
 * This is used to (de)compress small inputs.
 */
static void build_fixed_huffman_tree( huffman_node *root )
{
  huffman_range range[ 4 ];

  range[ 0 ].end = 143;
  range[ 0 ].bit_length = 8;
  range[ 1 ].end = 255;
  range[ 1 ].bit_length = 9;
  range[ 2 ].end = 279;
  range[ 2 ].bit_length = 7;
  range[ 3 ].end = 287;
  range[ 3 ].bit_length = 8;
}

typedef struct
{
  FILE *source;
  unsigned char buf;
  unsigned char mask; // current bit position within buf; 8 is MSB
}
bit_stream;

/**
 * Read a bit from the stream.
 */
unsigned int next_bit( bit_stream *stream )
{
  unsigned int bit = 0;

  bit = ( stream->buf & stream->mask ) ? 1 : 0;
  // gzip specifies the bits within a byte "backwards".
  // confusing.
  stream->mask <<= 1;

  if ( !stream->mask )
  {
    stream->mask = 0x01;
    if ( fread( &stream->buf, 1, 1, stream->source ) < 1 )
    {
      perror( "Error reading compressed input" );
      // TODO need a long jump to exit here or something
    }
  }

  return bit;
}

/** 
 * Read "count" bits from the stream, and return their value.
 */
int read_bits( bit_stream *stream, int count )
{
  int bits_value = 0;

  while ( count-- )
  {
    bits_value = ( bits_value << 1 ) | next_bit( stream );
  }

  return bits_value;
}

int read_bits_inv( bit_stream *stream, int count )
{
  int bits_value = 0;
  int i = 0;
  int bit;

  for ( i = 0; i < count; i++ )
  {
    bit = next_bit( stream );
    bits_value |= ( bit << i );
  }

  return bits_value;
}

/** 
 * Build a huffman tree from input as specified in section 3.2.7
 */
static void read_dynamic_huffman_tree( bit_stream *stream, 
                                       huffman_node *literals_root,
                                       huffman_node *distances_root )
{
  int hlit;
  int hdist;
  int hclen;
  int i, j;
  int code_lengths[ 19 ];
  huffman_range code_length_ranges[ 19 ];
  int *alphabet;
  huffman_range *alphabet_ranges;
  huffman_node code_lengths_root;
  huffman_node *code_lengths_node;

  static int code_length_offsets[] = {
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

  hlit = read_bits_inv( stream, 5 );
  hdist = read_bits_inv( stream, 5 );
  hclen = read_bits_inv( stream, 4 );

  memset( code_lengths, '\0', sizeof( code_lengths ) );
  for ( i = 0; i < ( hclen + 4 ); i++ )
  {
    code_lengths[ code_length_offsets[ i ] ] = read_bits_inv( stream, 3 );
  }

  // Turn those into actionable ranges for the huffman tree routine
  j = 0;  // j becomes the length of the range array
  for ( i = 0; i < 19; i++ )
  {
    if ( ( i > 0 ) && ( code_lengths[ i ] != code_lengths[ i - 1 ] ) )
    {
      j++;
    }
    code_length_ranges[ j ].end = i;
    code_length_ranges[ j ].bit_length = code_lengths[ i ];
  }

  memset( &code_lengths_root, '\0', sizeof( huffman_node ) );
  build_huffman_tree( &code_lengths_root, j + 1, code_length_ranges );

  // read the literal/length alphabet; this is encoded using the huffman
  // tree from the previous step
  i = 0;
  alphabet = ( int * ) malloc( ( hlit + hdist + 258 ) * sizeof( int ) );
  alphabet_ranges = ( huffman_range * ) malloc( ( hlit + hdist + 258 ) * sizeof( huffman_range ) );
  code_lengths_node = &code_lengths_root;
  while ( i < ( hlit + hdist + 258 ) )
  {
    if ( next_bit( stream ) )
    {
      code_lengths_node = code_lengths_node->one;
    }
    else
    {
      code_lengths_node = code_lengths_node->zero;
    }

    if ( code_lengths_node->code != -1 )
    {
      if ( code_lengths_node->code > 15 )
      {
        int repeat_length;

        switch ( code_lengths_node->code )
        {
          case 16:
            repeat_length = read_bits_inv( stream, 2 ) + 3;
            break;
          case 17:
            repeat_length = read_bits_inv( stream, 3 ) + 3;
            break;
          case 18:
            repeat_length = read_bits_inv( stream, 7 ) + 11;
            break;
        }

        while ( repeat_length-- )
        {
          if ( code_lengths_node->code == 16 )
          {
            alphabet[ i ] = alphabet[ i - 1 ];
          }
          else
          {
            alphabet[ i ] = 0;
          }
          i++;
        }
      }
      else
      {
        alphabet[ i ] = code_lengths_node->code;
        i++;
      }

      code_lengths_node = &code_lengths_root;
    }
  }

  // now, split the alphabet in two parts and turn each into a huffman
  // tree

  // Ok, now the alphabet lengths have been read.  Turn _those_
  // into a valid range declaration and build the final huffman
  // code from it.
  j = 0;
  for ( i = 0; i <= ( hlit + 257 ); i++ )
  {
    if ( ( i > 0 ) && ( alphabet[ i ] != alphabet[ i - 1 ] ) )
    {
      j++;
    }
    alphabet_ranges[ j ].end = i;
    alphabet_ranges[ j ].bit_length = alphabet[ i ];
  }

  build_huffman_tree( literals_root, j, alphabet_ranges );

  i--;
  j = 0;
  for ( ; i <= ( hdist + hlit + 258 ); i++ )
  {
    if ( ( i > ( 257 + hlit ) ) && ( alphabet[ i ] != alphabet[ i - 1 ] ) )
    {
      j++;
    }
    alphabet_ranges[ j ].end = i - ( 257 + hlit );
    alphabet_ranges[ j ].bit_length = alphabet[ i ];
  }

  build_huffman_tree( distances_root, j, alphabet_ranges );

  free( alphabet );
  free( alphabet_ranges );
}

#define MAX_DISTANCE  32768

static int inflate_huffman_codes( bit_stream *stream, 
                                  huffman_node *literals_root,
                                  huffman_node *distances_root )
{
  huffman_node *node;
  int stop_code = 0;
  unsigned char buf[ MAX_DISTANCE ];
  unsigned char *ptr = buf;

  int extra_length_addend[] = { 
    11, 13, 15, 17, 19, 23, 27,
    31, 35, 43, 51, 59, 67, 83,
    99, 115, 131, 163, 195, 227 
  };
  int extra_dist_addend[] = {
    4, 6, 8, 12, 16, 24, 32, 48,
    64, 96, 128, 192, 256, 384,
    512, 768, 1024, 1536, 2048,
    3072, 4096, 6144, 8192,
    12288, 16384, 24576 
  };

  node = literals_root;

  while ( !stop_code )
  {
    if ( feof( stream->source ) )
    {
      fprintf( stderr, "Premature end of file.\n" );
      return 1;
    }

    if ( next_bit( stream ) )
    {
      node = node->one;
    }
    else
    {
      node = node->zero;
    }

    if ( node->code != -1 )
    {
      // Found a leaf in the tree; decode a symbol
      assert( node->code < 286 );  // should never happen (?)
      // leaf node; output it
      if ( node->code < 256 )
      {
        *(ptr++) = node->code;
      }
      if ( node->code == 256 )
      {
        stop_code = 1;
        break;
      }
      if ( node->code > 256 )
      {
        int length;
        int dist;
        int extra_bits;
        // This is a back-pointer to a position in the stream
        // Interpret the length here as specified in 3.2.5
        if ( node->code < 265 )
        {
          length = node->code - 254;
        }
        else
        {
          if ( node->code < 285 )
          {
            extra_bits = read_bits_inv( stream, ( node->code - 261 ) / 4 );

            length = extra_bits + extra_length_addend[ node->code - 265 ];
          }
          else
          {
            length = 258;
          }
        }

        // The length is followed by the distance.
        // The distance is coded in 5 bits, and may be
        // followed by extra bits as specified in 3.2.5
        if ( distances_root == NULL )
        {
          // Hardcoded distances
          dist = read_bits( stream, 5 );
        }
        else
        {
          // Dynamic distances
          node = distances_root;
          while ( node->code == -1 )
          {
            if ( next_bit( stream ) )
            {
              node = node->one;
            }
            else
            {
              node = node->zero;
            }
          }
          dist = node->code;
        }

        if ( dist > 3 )
        {
          int extra_dist = read_bits_inv( stream, ( dist - 2 ) / 2 );

          // Embed the logic in the table at the end of 3.2.5
          dist = extra_dist + extra_dist_addend[ dist - 4 ];
        }

        // TODO change buf into a circular array so that it
        // can handle files of size > 32768 bytes
        {
          unsigned char *backptr = ptr - dist - 1;

          while ( length-- )
          {
            // Note that ptr & backptr can overlap
            *(ptr++) = *(backptr++);
          }
        }
      }
      node = literals_root;
    }
  }

  *ptr = '\0';
  printf( "%s\n", buf );

  return 0;
}

/** 
 * Decompress an input stream compliant to RFC 1951 deflation.
 */
static int inflate( FILE *compressed_input )
{
  // bit 8 set indicates that this is the last block
  // bits 7 & 6 indicate compression type
  unsigned char block_format;
  bit_stream stream;
  int last_block;
  huffman_node literals_root;
  huffman_node distances_root;

  stream.source = compressed_input;
  fread( &stream.buf, 1, 1, compressed_input );
  stream.mask = 0x01;

  do
  {
    last_block = next_bit( &stream );
    block_format = read_bits_inv( &stream, 2 );

    switch ( block_format )
    {
      case 0x00:
        printf( "Uncompressed block.\n" );
        fprintf( stderr, "uncompressed block type not supported.\n" );
        return 1;
        break;
      // Note, backwards from the spec, since the bits are being read
      // right-to-left.
      case 0x01:
        memset( &literals_root, '\0', sizeof( huffman_node ) );
        build_fixed_huffman_tree( &literals_root );
        inflate_huffman_codes( &stream, &literals_root, NULL );
        break;
      case 0x02:
        memset( &literals_root, '\0', sizeof( huffman_node ) );
        memset( &distances_root, '\0', sizeof( huffman_node ) );
        read_dynamic_huffman_tree( &stream, &literals_root, &distances_root );
        inflate_huffman_codes( &stream, &literals_root, &distances_root );
        break;
      default:
        fprintf( stderr, "Error, unsupported block type %x.\n", block_format );
        return 1;
        break;
    }
  }
  while ( !last_block );

  return 0;
}

#define MAX_BUF 255

/**
 * Read a null-terminated string from a file.  Null terminated
 * strings in files suck.
 */
static int read_string( FILE *in, unsigned char **target )
{
  unsigned char buf[ MAX_BUF ];
  unsigned char *buf_ptr;

  buf_ptr = buf;

  // TODO deal with strings > MAX_BUF
  do
  {
    if ( fread( buf_ptr, 1, 1, in ) < 1 )
    {
      perror( "Error reading string value" );
      return 1;
    }
  }
  while ( *( buf_ptr++ ) );

  *target = ( unsigned char * ) malloc( buf_ptr - buf );
  strcpy( *target, buf );

  return 0;
}

/**
 * Strip off an RFC 1952-compliant gzip file header and
 * decompress to stdout.
 */
int main( int argc, char *argv[ ] )
{
  FILE *in;
  gzip_file gzip;

  gzip.extra = NULL;
  gzip.fname = NULL;
  gzip.fcomment = NULL;

  if ( argc < 2 )
  {
    fprintf( stderr, "Usage: %s <gzipped input file>\n", argv[ 0 ] );
    exit( 1 );
  }

  in = fopen( argv[ 1 ], "r" );
  
  if ( !in )
  {
    fprintf( stderr, "Unable to open file '%s' for reading.\n", argv[ 1 ] );
    exit( 1 );
  }

  // TODO ought to deal with short reads here
  if ( fread( &gzip.header, sizeof( gzip_header ), 1, in ) < 1 )
  {
    perror( "Error reading header" );
    goto done;
  }
  if ( ( gzip.header.id[ 0 ] != 0x1f ) || ( gzip.header.id[ 1 ] != 0x8b ) )
  {
    fprintf( stderr, "Input not in gzip format.\n" );
    goto done;
  }
  if ( gzip.header.compression_method != 8 )
  {
    fprintf( stderr, "Unrecognized compression method.\n" );
    goto done;
  }

  if ( gzip.header.flags & FEXTRA )
  {
    // TODO spec seems to indicate that this is little-endian;
    // htons for big-endian machines?
    if ( fread( &gzip.xlen, 2, 1, in ) < 1 )
    {
      perror( "Error reading extras length" );
      goto done;
    }
    gzip.extra = ( unsigned char * ) malloc( gzip.xlen );
    if ( fread( gzip.extra, gzip.xlen, 1, in ) < 1 )
    {
      perror( "Error reading extras" );
      goto done;
    }
    // TODO interpret the extra data
  }

  // TODO if FNAME or FCOMMENT, null-terminated name or comments
  // follow...
  if ( gzip.header.flags & FNAME )
  {
    if ( read_string( in, &gzip.fname ) )
    {
      goto done;
    }
  }

  if ( gzip.header.flags & FCOMMENT )
  {
    if ( read_string( in, &gzip.fcomment ) )
    {
      goto done;
    }
  }

  if ( gzip.header.flags & FHCRC )
  {
    if ( fread( &gzip.crc16, 2, 1, in ) < 1 )
    {
      perror( "Error reading CRC16" );
      goto done;
    }
  }

  // compressed blocks follow
  if ( inflate( in ) )
  {
    goto done;
  }

  // TODO read and validate CRC32 & ISIZE which are the trailer
  // values.
  if ( fread( &gzip.crc32, 2, 1, in ) < 1 )
  {
    perror( "Error reading CRC32" );
    goto done;
  }

  if ( fread( &gzip.isize, 2, 1, in ) < 1 )
  {
    perror( "Error reading isize" );
    goto done;
  }

  // TODO check the CRC32

done:
  free( gzip.extra );
  free( gzip.fname );
  free( gzip.fcomment );

  if ( fclose( in ) )
  {
    perror( "Unable to close input file.\n" );
    exit( 1 );
  }

  exit( 0 );
}
