import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_owner_app/models/profile.dart';
import 'package:restaurant_owner_app/screens/home_shell.dart';
import 'package:restaurant_owner_app/screens/modules.dart' as m;
import 'package:restaurant_owner_app/services/api_client.dart';
import 'package:restaurant_owner_app/services/auth_controller.dart';
import 'package:restaurant_owner_app/services/date_range.dart';
import 'package:restaurant_owner_app/services/report_export.dart';
import 'package:restaurant_owner_app/services/restaurant_time.dart';
import 'package:restaurant_owner_app/services/rest_client.dart';
import 'package:restaurant_owner_app/ui/gaia/gaia.dart';
import 'package:restaurant_owner_app/ui/theme/app_theme.dart';
import 'package:restaurant_owner_app/ui/theme/appearance.dart';
import 'package:restaurant_owner_app/ui/widgets/empty_state.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_card.dart';
import 'package:restaurant_owner_app/ui/widgets/fork_tabs.dart';
import 'package:restaurant_owner_app/widgets/module_navigator.dart';

import 'search_contract.dart';

/// Insights → Reports: the nine MIS / control reports.
///
/// These are fraud-control documents, so the tests pin the promises that make a
/// number trustworthy rather than the pixels:
///   * the screen NEVER writes — a control report that could mutate anything is
///     a control report nobody should sign;
///   * the TOTALS row is the WINDOW's totals, and only the columns the SERVER
///     marks summable carry one;
///   * an export carries the WHOLE window, not the page on screen, with the
///     server's own caveats attached and money as raw numbers a sheet can sum;
///   * the same window shows the same grand total on Sales, Order and
///     Settlement Summary — the reconciliation the backend proves in jest, read
///     off the actual screens;
///   * a 15-column table degrades to a card per row on a phone, with every
///     value still glued to its own label.

// ---------------------------------------------------------------- fixtures --

/// Two settled bills, ₹1200 + ₹800. Every summary below is cut from the same
/// pair, so the three headline numbers MUST agree.
const _salesSummary = {
  'meta': {
    'report': 'sales_summary',
    'title': 'Sales Summary',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': [
      'Bills are counted on the day they were SETTLED, in the restaurant timezone.',
      'Round off is always 0: no bill field records a rounding adjustment.',
    ],
  },
  'columns': [
    {'key': 'bucket', 'label': 'Period', 'type': 'text'},
    {'key': 'bills', 'label': 'Bills', 'type': 'int', 'total': true},
    {'key': 'covers', 'label': 'Covers', 'type': 'int', 'total': true},
    {'key': 'gross', 'label': 'Gross', 'type': 'money', 'total': true},
    {'key': 'discount', 'label': 'Discount', 'type': 'money', 'total': true},
    {'key': 'net', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'service_charge', 'label': 'Service charge', 'type': 'money', 'total': true},
    {'key': 'tax', 'label': 'Tax', 'type': 'money', 'total': true},
    {'key': 'round_off', 'label': 'Round off', 'type': 'money', 'total': true, 'default_on': false},
    {'key': 'grand_total', 'label': 'Grand total', 'type': 'money', 'total': true},
    {'key': 'abv', 'label': 'ABV', 'type': 'money'},
    {'key': 'apc', 'label': 'APC (pre-tax)', 'type': 'money'},
  ],
  'totals': {
    'gross': 1900.0, 'discount': 100.0, 'net': 1800.0, 'service_charge': 0.0,
    'tax': 200.0, 'round_off': 0.0, 'grand_total': 2000.0, 'refund': 0.0,
    'refunded_tax': 0.0, 'bills': 2, 'covers': 5, 'discounted_bills': 1,
    'estimated_discount_bills': 0, 'apc': 360.0, 'abv': 1000.0,
    'bills_without_covers': 0,
  },
  'bucket': 'day',
  'series': [
    {
      'bucket': '2026-08-01', 'bills': 1, 'covers': 3, 'gross': 1300.0, 'discount': 100.0,
      'net': 1200.0, 'service_charge': 0.0, 'tax': 0.0, 'round_off': 0.0,
      'grand_total': 1200.0, 'refund': 0.0, 'abv': 1200.0, 'apc': 400.0,
    },
    {
      'bucket': '2026-08-02', 'bills': 1, 'covers': 2, 'gross': 600.0, 'discount': 0.0,
      'net': 600.0, 'service_charge': 0.0, 'tax': 200.0, 'round_off': 0.0,
      'grand_total': 800.0, 'refund': 0.0, 'abv': 800.0, 'apc': 300.0,
    },
  ],
  'by_order_type': [
    {'order_type': 'Dine-in', 'bills': 2, 'grand_total': 2000.0, 'share_pct': 100.0},
  ],
};

/// Sales Summary over a period that settled nothing. Its rows live under
/// `series`, not `rows`, and its chrome (six tiles and the money ladder) is
/// drawn whether or not there are any.
final _emptySalesSummary = <String, dynamic>{
  ..._salesSummary,
  'totals': {
    'gross': 0.0, 'discount': 0.0, 'net': 0.0, 'service_charge': 0.0,
    'tax': 0.0, 'round_off': 0.0, 'grand_total': 0.0, 'refund': 0.0,
    'refunded_tax': 0.0, 'bills': 0, 'covers': 0, 'discounted_bills': 0,
    'estimated_discount_bills': 0, 'apc': 0.0, 'abv': 0.0,
    'bills_without_covers': 0,
  },
  'series': <Map<String, dynamic>>[],
  'by_order_type': <Map<String, dynamic>>[],
};

const _orderSummary = {
  'meta': {
    'report': 'order_summary',
    'title': 'Order Summary',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': ['Totals are computed over the whole window, never the page.'],
  },
  'columns': [
    {'key': 'settled_at', 'label': 'Date & time', 'type': 'datetime'},
    {'key': 'bill_no', 'label': 'Bill No.', 'type': 'text'},
    {'key': 'order_type', 'label': 'Type', 'type': 'text'},
    {'key': 'table_name', 'label': 'Table', 'type': 'text'},
    {'key': 'covers', 'label': 'Covers', 'type': 'int'},
    {'key': 'waiter', 'label': 'Waiter', 'type': 'text'},
    {'key': 'item_count', 'label': 'Items', 'type': 'int', 'total': true},
    {'key': 'net', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'service_charge', 'label': 'Service charge', 'type': 'money', 'total': true, 'default_on': false},
    {'key': 'tax', 'label': 'Tax', 'type': 'money', 'total': true},
    {'key': 'grand_total', 'label': 'Grand total', 'type': 'money', 'total': true},
    {'key': 'payment_method', 'label': 'Payment', 'type': 'text'},
    {'key': 'status', 'label': 'Status', 'type': 'text'},
  ],
  'rows': [
    {
      'bill_id': 'bill-1', 'bill_no': '101', 'settled_at': '2026-08-01T13:20:00.000Z',
      'order_type': 'Dine-in', 'table_name': 'T1', 'covers': 3, 'waiter': 'Asha',
      'item_count': 4, 'gross': 1300.0, 'discount': 100.0, 'net': 1200.0,
      'service_charge': 0.0, 'tax': 0.0, 'grand_total': 1200.0, 'refund': 0.0,
      'payment_method': 'Cash', 'status': 'Paid',
    },
    {
      'bill_id': 'bill-2', 'bill_no': '102', 'settled_at': '2026-08-02T15:05:00.000Z',
      'order_type': 'Dine-in', 'table_name': 'T4', 'covers': 2, 'waiter': 'Vikram',
      'item_count': 3, 'gross': 600.0, 'discount': 0.0, 'net': 600.0,
      'service_charge': 0.0, 'tax': 200.0, 'grand_total': 800.0, 'refund': 0.0,
      'payment_method': 'UPI', 'status': 'Paid',
    },
  ],
  'totals': {
    'gross': 1900.0, 'discount': 100.0, 'net': 1800.0, 'service_charge': 0.0,
    'tax': 200.0, 'round_off': 0.0, 'grand_total': 2000.0, 'refund': 0.0,
    'refunded_tax': 0.0, 'bills': 2, 'covers': 5, 'discounted_bills': 1,
    'estimated_discount_bills': 0, 'apc': 360.0, 'abv': 1000.0,
    'bills_without_covers': 0, 'item_count': 7,
  },
  'page': {'limit': 100, 'offset': 0, 'total': 2, 'has_more': false},
};

const _settlementSummary = {
  'meta': {
    'report': 'settlement_summary',
    'title': 'Settlement Summary',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': ['Refunds are shown, not netted off the collected figure.'],
  },
  'columns': [
    {'key': 'method', 'label': 'Payment mode', 'type': 'text'},
    {'key': 'bills', 'label': 'Bills', 'type': 'int', 'total': true},
    {'key': 'amount', 'label': 'Collected', 'type': 'money', 'total': true},
    {'key': 'share_pct', 'label': '% of takings', 'type': 'percent'},
    {'key': 'refund', 'label': 'Refunds', 'type': 'money', 'total': true},
    {'key': 'net_amount', 'label': 'Net', 'type': 'money', 'total': true},
  ],
  'rows': [
    {'method': 'Cash', 'bills': 1, 'amount': 1200.0, 'share_pct': 60.0, 'refund': 0.0, 'net_amount': 1200.0},
    {'method': 'UPI', 'bills': 1, 'amount': 800.0, 'share_pct': 40.0, 'refund': 0.0, 'net_amount': 800.0},
  ],
  'totals': {
    'bills': 2, 'amount': 2000.0, 'refund': 0.0, 'net_amount': 2000.0,
    'split_bills': 0, 'unallocated': 0.0,
  },
};

/// The same sheet with money the split tenders could not account for. Seeing it
/// is the point — the backend says this should always be 0.
Map<String, dynamic> _settlementWithHole() {
  final copy = jsonDecode(jsonEncode(_settlementSummary)) as Map<String, dynamic>;
  (copy['totals'] as Map)['unallocated'] = 45.5;
  return copy;
}

const _voidKot = {
  'meta': {
    'report': 'void_kot',
    'title': 'Void KOT',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': ['A void is Orders.status = 5. No void reason, stage or authoriser exists in the schema.'],
  },
  'columns': [
    {'key': 'placed_at', 'label': 'Placed', 'type': 'datetime'},
    {'key': 'voided_at', 'label': 'Voided', 'type': 'datetime'},
    {'key': 'order_id', 'label': 'KOT / Order', 'type': 'text'},
    {'key': 'table_name', 'label': 'Table', 'type': 'text'},
    {'key': 'items_text', 'label': 'Items', 'type': 'text'},
    {'key': 'order_type', 'label': 'Type', 'type': 'text'},
    {'key': 'item_count', 'label': 'Lines', 'type': 'int', 'total': true},
    {'key': 'qty', 'label': 'Qty', 'type': 'int', 'total': true},
    {'key': 'value', 'label': 'Value', 'type': 'money', 'total': true},
    {'key': 'voided_by', 'label': 'Voided by', 'type': 'text'},
  ],
  'rows': [
    {
      'order_id': 'order-9', 'kot_no': null, 'table_name': 'T7',
      'placed_at': '2026-08-01T12:00:00.000Z', 'voided_at': '2026-08-01T12:09:00.000Z',
      'voided_by': 'Ravi', 'order_type': 'Dine-in', 'item_count': 2, 'qty': 3,
      'value': 540.0,
      'items_text': 'Paneer Tikka (Half) x2; Dal x1',
      'items': [
        {'name': 'Paneer Tikka', 'variation': 'Half', 'quantity': 2, 'price': 180.0},
        {'name': 'Dal', 'variation': null, 'quantity': 1, 'price': 180.0},
      ],
    },
  ],
  'totals': {'voids': 1, 'qty': 3, 'value': 540.0, 'item_count': 2},
  'page': {'limit': 100, 'offset': 0, 'total': 1, 'has_more': false},
};

const _itemWise = {
  'meta': {
    'report': 'item_wise',
    'title': 'Item Wise',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': ['Aggregated by order placement time, so it does not tie to the Sales Summary.'],
  },
  'columns': [
    {'key': 'name', 'label': 'Item', 'type': 'text'},
    {'key': 'category', 'label': 'Category', 'type': 'text'},
    {'key': 'qty', 'label': 'Qty', 'type': 'int', 'total': true},
    {'key': 'gross_amount', 'label': 'Gross', 'type': 'money', 'total': true},
    {'key': 'net_amount', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'avg_selling_price', 'label': 'Avg selling price', 'type': 'money'},
    {'key': 'contribution_pct', 'label': '% contribution', 'type': 'percent'},
  ],
  'rows': [
    {
      'name': 'Paneer Tikka', 'category': 'Starters', 'qty': 6, 'gross_amount': 1440.0,
      'discount_amount': 0.0, 'net_amount': 1440.0, 'avg_selling_price': 240.0,
      'contribution_pct': 62.5, 'dine_in_qty': 6, 'takeaway_qty': 0,
      'delivery_qty': 0, 'other_qty': 0,
    },
  ],
  'totals': {
    'items': 1, 'qty': 6, 'gross_amount': 1440.0, 'discount_amount': 0.0,
    'net_amount': 1440.0, 'dine_in_qty': 6, 'takeaway_qty': 0, 'delivery_qty': 0, 'other_qty': 0,
  },
  'page': {'limit': 100, 'offset': 0, 'total': 1, 'has_more': false},
  'bill_level_discount': 100.0,
  'category_exact': false,
};

/// The same report over a period that sold nothing.
final _emptyItemWise = <String, dynamic>{
  ..._itemWise,
  'rows': <Map<String, dynamic>>[],
  'totals': {
    'items': 0, 'qty': 0, 'gross_amount': 0.0, 'discount_amount': 0.0,
    'net_amount': 0.0, 'dine_in_qty': 0, 'takeaway_qty': 0, 'delivery_qty': 0, 'other_qty': 0,
  },
  'page': {'limit': 100, 'offset': 0, 'total': 0, 'has_more': false},
  'bill_level_discount': 0.0,
};

const _billEdit = {
  'meta': {
    'report': 'bill_edit',
    'title': 'Bill Edit',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': ['No before/after amounts are recorded anywhere by the write paths.'],
  },
  'columns': [
    {'key': 'at', 'label': 'Date & time', 'type': 'datetime'},
    {'key': 'action', 'label': 'Change', 'type': 'text'},
    {'key': 'table_name', 'label': 'Table', 'type': 'text'},
    {'key': 'item', 'label': 'Item', 'type': 'text'},
    {'key': 'by', 'label': 'By', 'type': 'text'},
    {'key': 'description', 'label': 'Detail', 'type': 'text'},
  ],
  'rows': [
    {
      'audit_id': 'a1', 'at': '2026-08-01T13:10:00.000Z', 'kind': 'remove_item',
      'action': 'Item removed', 'description': 'Removed 1 x Paneer Tikka',
      'by': 'Ravi', 'bill_id': null, 'order_id': 'order-3', 'table_name': 'T1',
      'item': 'Paneer Tikka',
    },
  ],
  'totals': {
    'edits': 1,
    'by_kind': [{'kind': 'remove_item', 'label': 'Item removed', 'count': 1}],
  },
  'page': {'limit': 100, 'offset': 0, 'total': 1, 'has_more': false},
};

const _executive = {
  'meta': {
    'report': 'executive_summary',
    'title': 'Executive Summary',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'all',
    'outlet_name': null,
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': ['Growth is blank when the previous period was zero.'],
  },
  'columns': [
    {'key': 'outlet_name', 'label': 'Outlet', 'type': 'text'},
    {'key': 'bills', 'label': 'Bills', 'type': 'int', 'total': true},
    {'key': 'covers', 'label': 'Covers', 'type': 'int', 'total': true},
    {'key': 'net', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'grand_total', 'label': 'Grand total', 'type': 'money', 'total': true},
    {'key': 'previous_grand_total', 'label': 'Previous period', 'type': 'money', 'total': true},
    {'key': 'growth_pct', 'label': 'Growth %', 'type': 'percent'},
    {'key': 'share_pct', 'label': '% of group', 'type': 'percent'},
  ],
  'totals': {
    'gross': 1900.0, 'discount': 100.0, 'net': 1800.0, 'service_charge': 0.0,
    'tax': 200.0, 'round_off': 0.0, 'grand_total': 2000.0, 'refund': 0.0,
    'refunded_tax': 0.0, 'bills': 2, 'covers': 5, 'discounted_bills': 1,
    'estimated_discount_bills': 0, 'apc': 360.0, 'abv': 1000.0,
    'bills_without_covers': 0, 'previous_grand_total': 1600.0,
    'growth_pct': 25.0, 'share_pct': 100.0,
  },
  'current': {'grand_total': 2000.0, 'net': 1800.0, 'bills': 2, 'covers': 5},
  'previous': {'grand_total': 1600.0, 'net': 1450.0, 'bills': 2, 'covers': 4},
  'previous_window': {'from': '2026-07-30', 'to': '2026-07-31', 'days': 2, 'basis': 'days'},
  'growth': {
    'grand_total': 25.0, 'net': 24.1, 'bills': 0.0, 'covers': 25.0,
    'abv': 25.0, 'apc': -1.0, 'discount': 0.0,
  },
  'by_outlet': [
    {
      'outlet_id': 'out-2', 'outlet_name': 'Baner', 'bills': 1, 'covers': 2,
      'net': 600.0, 'grand_total': 800.0, 'abv': 800.0, 'apc': 300.0,
      'previous_grand_total': 600.0, 'growth_pct': 33.3, 'share_pct': 40.0,
    },
    {
      'outlet_id': 'out-1', 'outlet_name': 'Kalyani Nagar', 'bills': 1, 'covers': 3,
      'net': 1200.0, 'grand_total': 1200.0, 'abv': 1200.0, 'apc': 400.0,
      'previous_grand_total': 1000.0, 'growth_pct': 20.0, 'share_pct': 60.0,
    },
  ],
};

const _coverSize = {
  'meta': {
    'report': 'cover_size_summary',
    'title': 'Cover Size Summary',
    'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
    'timezone': 'Asia/Kolkata',
    'outlet_scope': 'outlet',
    'outlet_name': 'Kalyani Nagar',
    'generated_at': '2026-08-03T04:00:00.000Z',
    'notes': ['A party is one SEATING, counted once however many ways the bill was split.'],
  },
  'columns': [
    {'key': 'party_size', 'label': 'Party size', 'type': 'int'},
    {'key': 'parties', 'label': 'Parties', 'type': 'int', 'total': true},
    {'key': 'bills', 'label': 'Bills', 'type': 'int', 'total': true},
    {'key': 'covers', 'label': 'Covers', 'type': 'int', 'total': true},
    {'key': 'net', 'label': 'Net', 'type': 'money', 'total': true},
    {'key': 'grand_total', 'label': 'Grand total', 'type': 'money', 'total': true},
    {'key': 'spend_per_cover', 'label': 'Spend per cover (pre-tax)', 'type': 'money'},
  ],
  'rows': [
    {
      'party_size': 2, 'parties': 1, 'bills': 1, 'covers': 2, 'net': 600.0,
      'grand_total': 800.0, 'spend_per_cover': 300.0, 'avg_bill_value': 800.0, 'share_pct': 40.0,
    },
    {
      'party_size': 3, 'parties': 1, 'bills': 1, 'covers': 3, 'net': 1200.0,
      'grand_total': 1200.0, 'spend_per_cover': 400.0, 'avg_bill_value': 1200.0, 'share_pct': 60.0,
    },
  ],
  'totals': {
    'gross': 1900.0, 'discount': 100.0, 'net': 1800.0, 'service_charge': 0.0,
    'tax': 200.0, 'round_off': 0.0, 'grand_total': 2000.0, 'refund': 0.0,
    'refunded_tax': 0.0, 'bills': 2, 'covers': 5, 'discounted_bills': 1,
    'estimated_discount_bills': 0, 'apc': 360.0, 'abv': 1000.0,
    'bills_without_covers': 0, 'parties': 2,
  },
};

Map<String, dynamic> _discountPage({required int offset}) => {
      'meta': {
        'report': 'discount',
        'title': 'Discount',
        'window': {'from': '2026-08-01', 'to': '2026-08-02', 'days': 2, 'source': 'range', 'clamped': false},
        'timezone': 'Asia/Kolkata',
        'outlet_scope': 'outlet',
        'outlet_name': 'Kalyani Nagar',
        'generated_at': '2026-08-03T04:00:00.000Z',
        'notes': ['A percentage discount is reconstructed from the settled total.'],
      },
      'columns': const [
        {'key': 'settled_at', 'label': 'Date & time', 'type': 'datetime'},
        {'key': 'bill_no', 'label': 'Bill No.', 'type': 'text'},
        {'key': 'discount_type', 'label': 'Type', 'type': 'text'},
        {'key': 'discount_amount', 'label': 'Discount', 'type': 'money', 'total': true},
        {'key': 'reason', 'label': 'Reason', 'type': 'text'},
        {'key': 'grand_total', 'label': 'Grand total', 'type': 'money', 'total': true},
      ],
      // Page 1 of the sweep (limit 500, offset 0) holds two rows; page 2 holds
      // the third. The first screen page (limit 100) shows only the first two.
      'rows': offset == 0
          ? [
              {
                'bill_id': 'bill-1', 'bill_no': '101', 'settled_at': '2026-08-01T13:20:00.000Z',
                'discount_type': 'flat', 'discount_value': 100.0, 'discount_amount': 100.0,
                'estimated': false, 'reason': 'Regular guest', 'grand_total': 1200.0,
              },
              {
                'bill_id': 'bill-2', 'bill_no': '102', 'settled_at': '2026-08-02T15:05:00.000Z',
                'discount_type': 'percent', 'discount_value': 10.0, 'discount_amount': 80.0,
                'estimated': true, 'reason': 'Staff meal', 'grand_total': 800.0,
              },
            ]
          : [
              {
                'bill_id': 'bill-3', 'bill_no': '103', 'settled_at': '2026-08-02T21:40:00.000Z',
                'discount_type': 'flat', 'discount_value': 50.0, 'discount_amount': 50.0,
                'estimated': false, 'reason': 'Late service', 'grand_total': 450.0,
              },
            ],
      'totals': const {
        'discounted_bills': 3, 'estimated_bills': 1, 'discount_amount': 230.0,
        'gross': 2680.0, 'net': 2450.0, 'grand_total': 2450.0, 'discount_pct_of_gross': 8.6,
      },
      'page': {'limit': 500, 'offset': offset, 'total': 3, 'has_more': offset == 0},
    };

const _billDetail = {
  'id': 'bill-1',
  'bill_no': '101',
  'table_name': 'T1',
  'items': [
    {'name': 'Paneer Tikka', 'quantity': 2, 'price': 240.0, 'line_total': 480.0},
  ],
  'taxes': [],
  'payment_splits': [],
  'orders': [],
  'items_subtotal': 1300.0,
  'discount_amount': 100.0,
  'taxable_base': 1200.0,
  'service_charge': 0.0,
  'tax_total': 0.0,
  'grand_total': 1200.0,
  'payment_method': 'Cash',
  'covers': 3,
};

const _kotDetail = {
  'id': 'order-9',
  'created_at': '2026-08-01T12:00:00.000Z',
  'updated_at': '2026-08-01T12:09:00.000Z',
  'status': 'Cancelled',
  'order_type': 'Dine-in',
  'table_name': 'T7',
  'customer': null,
  'taken_by': 'Ravi',
  'items': [
    {'name': 'Butter Naan', 'quantity': 3, 'price': 60.0, 'line_total': 180.0, 'note': null, 'station': null},
  ],
  'item_count': 1,
  'qty': 3,
  'value': 180.0,
  'bill_id': null,
  'bill_no': null,
  'trail': [
    {'at': '2026-08-01T12:09:00.000Z', 'action': 'Add Orders', 'description': 'Order -> Cancelled', 'by': 'Ravi'},
  ],
};

// -------------------------------------------------------------------- fake --

class _FakeApi extends ApiClient {
  _FakeApi({Map<String, dynamic>? extra}) : routes = {..._base, ...?extra};

  static final Map<String, dynamic> _base = <String, dynamic>{
    '/outlets': {
      'outlets': [
        {'id': 'out-1', 'outlet_name': 'Kalyani Nagar', 'is_active': true},
        {'id': 'out-2', 'outlet_name': 'Baner', 'is_active': true},
      ],
    },
    '/reports/mis/sales-summary': _salesSummary,
    '/reports/mis/order-summary': _orderSummary,
    '/reports/mis/settlement-summary': _settlementSummary,
    '/reports/mis/void-kot': _voidKot,
    '/reports/mis/item-wise': _itemWise,
    '/reports/mis/bill-edit': _billEdit,
    '/reports/mis/executive-summary': _executive,
    '/reports/mis/cover-size-summary': _coverSize,
    '/reports/mis/bill/bill-1': _billDetail,
    '/reports/mis/bill/bill-2': _billDetail,
    '/reports/mis/kot/order-9': _kotDetail,
    '/reports/mis/kot/order-3': _kotDetail,
  };

  final Map<String, dynamic> routes;

  /// Every request, verbatim, so a test can prove what was and was not asked.
  final List<String> calls = <String>[];

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'restaurantUsername': 'csrorganics',
          'res_id': 'res-1',
          'outlet_id': 'out-1',
          'role': 'admin',
          'actions_set': ['*'],
          'action_names': <String>[],
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    calls.add('$method $path');
    // THE READ-ONLY GUARANTEE, enforced rather than asserted after the fact: a
    // control report that could write anything is a control report nobody
    // should sign, and a write here would also reach the offline outbox.
    if (method != 'GET') {
      throw StateError('Reports must never write — saw $method $path');
    }
    final uri = Uri.parse('http://x$path');
    final base = uri.path;
    if (base == '/reports/mis/discount') {
      return _discountPage(offset: int.tryParse(uri.queryParameters['offset'] ?? '0') ?? 0);
    }
    final hit = routes[base];
    if (hit == null) throw ApiException('No fake route for $base', 404);
    return hit;
  }

  List<String> get gets => calls.where((c) => c.startsWith('GET ')).toList();
}

Widget _host(
  Widget child, {
  void Function(String)? switchOutlet,
  DesignSystem system = DesignSystem.rustic,
  double textScale = 1.0,
}) =>
    GaiaScope(
      system: system,
      child: MaterialApp(
        theme: system == DesignSystem.gaia ? GaiaTheme.dark() : AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ModuleNavigator(
          openModule: (_, {Map<String, dynamic>? target}) {},
          visibleLabels: const ['Reports', 'History', 'Accounting'],
          clearFocus: () {},
          switchOutlet: switchOutlet ?? (_) {},
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );

Future<_FakeApi> _mount(
  WidgetTester tester, {
  double width = 1400,
  double height = 1000,
  _FakeApi? api,
  void Function(String)? switchOutlet,
  DesignSystem system = DesignSystem.rustic,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(const SizedBox());
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final fake = api ?? _FakeApi();
  final auth = AuthController(api: fake);
  await auth.login('CSR Organics', 'admin', 'admin123');
  final rest = RestClient(auth);
  await tester.pumpWidget(_host(m.reportsModule(rest, auth.profile!),
      switchOutlet: switchOutlet, system: system, textScale: textScale));
  await tester.pumpAndSettle();
  return fake;
}

/// Nine tabs do not fit a 1400px desktop, let alone a 390px phone — the strip
/// scrolls, so a test has to scroll it exactly as a reader would. The label is
/// looked up inside the tab strip and in either case, because Gaia draws its
/// tab labels in capitals.
Future<void> _openTab(WidgetTester tester, String title) async {
  final tab = find
      .descendant(
        of: find.byType(ForkTabs),
        matching: find.byWidgetPredicate(
            (w) => w is Text && (w.data == title || w.data == title.toUpperCase()),
            description: 'tab label "$title"'),
      )
      .first;
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// A shell mount, so the module's PLACEMENT and GATE are pinned where they
/// actually live (home_shell's registry) and not merely asserted in prose.
class _ShellApi extends ApiClient {
  _ShellApi({required this.actions, required this.actionNames, required this.features, this.role});
  final List<String> actions;
  final List<String> actionNames;
  final Map<String, dynamic> features;

  /// The signed-in ROLE, when the case under test is about the role rather than
  /// about the action. Null keeps the old shorthand (wildcard = admin, anything
  /// else = waiter), which every other case here still uses.
  final String? role;

  @override
  Future<LoginResult> login(String restaurantName, String username, String password, {String? outletId}) async =>
      LoginResult(
        'test-token',
        Profile.fromJson(<String, dynamic>{
          'employeeId': 'e1',
          'restaurantName': 'CSR Organics',
          'role': role ?? (actions.contains('*') ? 'admin' : 'waiter'),
          'actions_set': actions,
          'action_names': actionNames,
          'features': features,
        }),
      );

  @override
  Future<dynamic> request(String method, String path, String token, [Object? body, String? outletId]) async {
    throw ApiException('No fake route for $path', 404);
  }
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required List<String> actions,
  required List<String> actionNames,
  Map<String, dynamic> features = const {},
  String? role,
}) async {
  await tester.pumpWidget(const SizedBox());
  // Tall on purpose: the nav rail is a lazily-built ListView, so a module that
  // sits below the fold is not in the tree at all — and this test is about
  // WHERE Reports is registered, not about scrolling a sidebar.
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final auth = AuthController(
      api: _ShellApi(
          actions: actions, actionNames: actionNames, features: features, role: role));
  await auth.login('CSR Organics', 'u', 'p');
  // Printer agent off: it opens a real socket and a keep-alive timer that
  // fake-async cannot own.
  await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), home: HomeShell(auth: auth, startPrinterAgent: false)));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    DateRangeMemory.reset();
    m.misResetReportMemory();
    ReportExporter.overrideDeliver = null;
    ReportExporter.overrideIsMobile = null;
  });

  tearDown(() {
    ReportExporter.overrideDeliver = null;
    ReportExporter.overrideIsMobile = null;
  });

  // ------------------------------------------------------- shell placement --

  testWidgets('the shell lists Reports under INSIGHTS, gated exactly as its routes are',
      (tester) async {
    // Admin: sees it, in the Insights group beside Analytics and History.
    await _pumpShell(tester, actions: const ['*'], actionNames: const []);
    expect(find.text('INSIGHTS'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);

    // A role granted only the accounting/analytics action the /reports/mis/*
    // routes actually validate — which is NAMED "View Order APC" — sees it too.
    await _pumpShell(
        tester,
        actions: const ['df75119b'],
        actionNames: const ['View Order APC'],
        role: 'manager');
    expect(find.text('Reports'), findsOneWidget);

    // A waiter does not. The gate is the server's, mirrored, not a wider one.
    await _pumpShell(tester, actions: const ['x'], actionNames: const ['Add Orders']);
    expect(find.text('Reports'), findsNothing);

    // AND A WAITER WHOSE TENANT GRANTED THAT ACTION STILL DOES NOT — the one
    // place this module's gate is deliberately NARROWER than the server's.
    //
    // `Roles.actions_performable` is per-tenant JSON, so "waiters cannot see the
    // restaurant's money" is not a promise the action gate can make: a
    // restaurant that ticked "View Order APC" for its waiters has genuinely
    // granted it, and the server will serve every /reports/mis/* route to them.
    // RoleScope is what answers the other question — what this person is here to
    // do — and it is the same override the Overview has applied to its money
    // blocks since 1.8.6. Without it, a floor plan with the rupees taken off it
    // sits two taps away from a full sales summary in the same nav.
    await _pumpShell(
        tester,
        actions: const ['df75119b'],
        actionNames: const ['View Orders', 'View Tables', 'View Order APC']);
    expect(find.text('Reports'), findsNothing,
        reason: 'a granted action changes what a waiter may READ, not what they ARE');
    // findsWidgets, not findsOneWidget: Tables is both a nav row and the open
    // tab's AppBar title, because it is the tab a waiter LANDS on.
    expect(find.text('Tables'), findsWidgets, reason: 'their own floor is untouched');

    // Nor does a tenant whose plan drops accounting — /reports is the prefix
    // that flag governs, so the tile goes with the 403.
    await _pumpShell(
      tester,
      actions: const ['*'],
      actionNames: const [],
      features: const {'accounting': false},
    );
    expect(find.text('Reports'), findsNothing);
    expect(find.text('Analytics'), findsOneWidget, reason: 'analytics is a different flag');
  });

  // ---------------------------------------------------------------- shell --

  testWidgets('the pack is exactly fifteen reports, and the shared shell is on every one',
      (tester) async {
    await _mount(tester);

    for (final t in const [
      'Item Wise', 'Discount', 'Void KOT', 'Bill Edit', 'Sales Summary',
      'Order Summary', 'Executive Summary', 'Cover Size Summary', 'Settlement Summary',
      // The six that migrations 034-039 finally gave data to. They are here
      // because the capture screens in this app now WRITE that data — an empty
      // tab is a promise the numbers cannot keep, which is why they were absent
      // until the writers existed.
      'NC Summary', 'Service Charge Deny', 'Group Summary',
      'Variation Summary', 'Tip Summary', 'Counter Summary',
    ]) {
      expect(find.text(t), findsWidgets, reason: '$t tab missing');
    }
    // No sixteenth tab: the industry-standard set is fifteen and inventing one
    // more would be a report with nothing behind it.
    expect(find.text('Tax Summary'), findsNothing);
    expect(find.text('Modifier'), findsNothing);

    // The shell, once, for all fifteen.
    expect(find.byKey(const ValueKey('reports-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-columns')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-export')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-outlet')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-grid')), findsOneWidget);
    // …and the clock the open tab is cut on, which is new and is not optional:
    // fifteen reports over one date range do not all date the same events.
    expect(find.byKey(const ValueKey('reports-basis')), findsOneWidget);
  });

  testWidgets('the time-wise toggle is offered ONLY where the server answers it', (tester) async {
    await _mount(tester);
    // Item Wise opens first — no bucket control.
    expect(find.byKey(const ValueKey('reports-bucket')), findsNothing);
    await _openTab(tester, 'Sales Summary');
    expect(find.byKey(const ValueKey('reports-bucket')), findsOneWidget);
    expect(find.text('Hour-wise'), findsOneWidget);
    await _openTab(tester, 'Settlement Summary');
    expect(find.byKey(const ValueKey('reports-bucket')), findsNothing);
  });

  testWidgets('nothing on this screen writes — every request is a GET', (tester) async {
    final api = await _mount(tester);
    for (final t in const [
      'Discount', 'Void KOT', 'Bill Edit', 'Sales Summary', 'Order Summary',
      'Executive Summary', 'Cover Size Summary', 'Settlement Summary',
    ]) {
      await _openTab(tester, t);
    }
    expect(api.calls, isNotEmpty);
    expect(api.calls.length, api.gets.length, reason: 'a non-GET reached the server');
  });

  testWidgets('the window rides on every report request, both days inclusive', (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Order Summary');
    final call = api.gets.lastWhere((c) => c.contains('/reports/mis/order-summary'));
    expect(call, contains('from='));
    expect(call, contains('to='));
    expect(call, contains('limit=100'));
    expect(call, contains('offset=0'));
  });

  // ------------------------------------------------------------ the grid ---

  testWidgets('the wide grid pins a header and a TOTALS row that says it is the whole period',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Order Summary');

    expect(find.byKey(const ValueKey('reports-grid')), findsOneWidget);
    expect(find.text('BILL NO.'), findsOneWidget, reason: 'header row');
    expect(find.text('101'), findsOneWidget);
    expect(find.text('102'), findsOneWidget);
    // The totals row is the WINDOW's, and it says so — a totals row that only
    // added up the rows on screen is how a control report understates a day.
    expect(find.text('TOTAL · whole period'), findsOneWidget);
    // ₹2000.00 appears in the totals row (grand_total) but not as a row value,
    // because neither bill is 2000.
    expect(find.text('₹2000.00'), findsWidgets);
  });

  testWidgets('only the columns the SERVER marks summable carry a total', (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Order Summary');

    // `covers` is an int column the server does NOT sum (a per-seating figure,
    // counted once per party), so the TOTALS ROW must stay blank under it —
    // while `item_count`, which the server DOES sum, shows 7.
    //
    // Scoped to the grid on purpose: the window's 5 covers are a real figure and
    // the headline tile above is entitled to show it. What must not happen is
    // that number appearing in the Covers column of the totals row, where it
    // would read as "3 + 2 = 5 covers billed" — a sum the server never made and
    // one that double-counts a party across split bills.
    final inGrid = find.descendant(
      of: find.byKey(const ValueKey('reports-grid')),
      matching: find.text('5'),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reports-grid')),
        matching: find.text('7'),
      ),
      findsOneWidget,
      reason: 'item_count total',
    );
    expect(inGrid, findsNothing,
        reason: 'covers were summed into a total the server never gave');
  });

  testWidgets('a column switched off leaves the grid', (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Order Summary');
    expect(find.text('WAITER'), findsOneWidget);
    expect(find.text('Asha'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reports-columns')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reports-col-waiter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('WAITER'), findsNothing);
    expect(find.text('Asha'), findsNothing);
    // A default-off column is off without anyone touching it.
    expect(find.text('SERVICE CHARGE'), findsNothing);
  });

  testWidgets('scrolling the grid sideways keeps the frozen column and does not throw',
      (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Order Summary');

    // The header and the totals row mirror the body's horizontal offset through
    // jumpTo; a mirror that fires mid-layout would assert here rather than in
    // front of an owner.
    await tester.drag(find.byKey(const ValueKey('reports-grid')), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The row's identity is still on screen, which is the whole point of
    // freezing it, and the totals row is still pinned under everything.
    expect(find.text('BILL NO.'), findsOneWidget);
    expect(find.text('TOTAL · whole period'), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey('reports-grid')), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Load more appends the next page instead of replacing the one on screen',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Discount');

    expect(find.text('101'), findsOneWidget);
    expect(find.text('103'), findsNothing);
    expect(find.textContaining('Showing 2 of 3 rows'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reports-more')));
    await tester.pumpAndSettle();

    expect(find.text('101'), findsOneWidget, reason: 'page one was replaced, not extended');
    expect(find.text('103'), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-more')), findsNothing);
    expect(api.gets.any((c) => c.contains('offset=2')), isTrue);
  });

  // ----------------------------------------------------------- drill-down ---

  testWidgets('an Order Summary row opens the SAME bill body the rest of the app shows',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Order Summary');
    await tester.tap(find.text('101'));
    await tester.pumpAndSettle();

    expect(api.gets.any((c) => c.contains('/reports/mis/bill/bill-1')), isTrue);
    // _closedBillBody's own furniture — the bill body History renders.
    expect(find.text('Paneer Tikka'), findsWidgets);
    expect(find.text('₹1200.00'), findsWidgets);
  });

  // CLIENT ITEM 1, cross-client parity. The row this sheet opens from says Item
  // total, Net and Gross; the web's drill-down for the same bill says Item total,
  // Net and Gross. The sheet used to say "Items subtotal", "Taxable base" and
  // "Grand total" — three names for the same three figures on the same screen.
  // History keeps the receipt's words (money_drilldowns_test.dart pins "base").
  testWidgets('the drill-down bill names its rungs Item total, Net and Gross — the words on the row', (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Order Summary');
    await tester.tap(find.text('101'));
    await tester.pumpAndSettle();

    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    Finder inSheet(String s) => find.descendant(of: sheet, matching: find.text(s));
    // The figure on the same line as a label, so a word on the wrong number fails.
    Finder rung(String label, String value) => find.descendant(
          of: find.ancestor(of: inSheet(label), matching: find.byType(Row)).first,
          matching: find.text(value),
        );

    expect(rung('Item total', '₹1300.00'), findsOneWidget);
    expect(rung('Net', '₹1200.00'), findsOneWidget);
    expect(rung('Gross', '₹1200.00'), findsOneWidget);
    for (final receiptWord in const ['Items subtotal', 'Taxable base', 'Grand total']) {
      expect(inSheet(receiptWord), findsNothing, reason: '"$receiptWord" is the receipt word, not the report word');
    }
    expect(inSheet('₹1200.00 net + ₹0.00 service + ₹0.00 tax = ₹1200.00'), findsOneWidget);
  });

  testWidgets('a Void KOT row opens the ticket and its audit trail', (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Void KOT');
    await tester.tap(find.text('order-9'));
    await tester.pumpAndSettle();

    expect(api.gets.any((c) => c.contains('/reports/mis/kot/order-9')), isTrue);
    expect(find.text('KITCHEN TICKET'), findsOneWidget);
    expect(find.text('Audit trail'), findsOneWidget);
    expect(find.text('Butter Naan'), findsOneWidget);
    expect(find.textContaining('Order -> Cancelled'), findsOneWidget);
  });

  testWidgets('a Sales Summary day row narrows the window to that day', (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    await tester.tap(find.text('2026-08-01'));
    await tester.pumpAndSettle();

    final call = api.gets.lastWhere((c) => c.contains('/reports/mis/sales-summary'));
    expect(call, contains('from=2026-08-01'));
    expect(call, contains('to=2026-08-01'));
  });

  testWidgets('an Executive Summary outlet row switches the whole app to that branch',
      (tester) async {
    final switched = <String>[];
    await _mount(tester, switchOutlet: switched.add);
    await _openTab(tester, 'Executive Summary');
    await tester.tap(find.text('Baner'));
    await tester.pumpAndSettle();
    expect(switched, ['out-2']);
  });

  // -------------------------------------------------------- the numbers ----

  testWidgets('Sales, Order and Settlement Summary show the SAME grand total for one window',
      (tester) async {
    await _mount(tester);

    await _openTab(tester, 'Sales Summary');
    expect(find.text('₹2000.00'), findsWidgets, reason: 'sales summary grand total');
    // And the ladder that produces it, rung by rung.
    expect(find.text('Money ladder'), findsOneWidget);
    // The client's words: Item total at the top, Gross (the grand total) at the
    // bottom. This fixture is an older backend's — `gross`, no `item_total` — so
    // the top rung is read off the deprecated alias.
    for (final rung in const ['Item total', 'Discount', 'Net', 'Service charge', 'Tax', 'Round off', 'Gross']) {
      expect(find.text(rung), findsWidgets, reason: '$rung rung missing');
    }
    expect(find.text('Grand total'), findsNothing);
    expect(find.text('₹1900.00'), findsWidgets, reason: 'item total');
    expect(find.text('₹1800.00'), findsWidgets, reason: 'net');

    await _openTab(tester, 'Order Summary');
    expect(find.text('₹2000.00'), findsWidgets, reason: 'order summary grand total');

    await _openTab(tester, 'Settlement Summary');
    expect(find.text('₹2000.00'), findsWidgets, reason: 'settlement grand total');
    expect(find.text('Cash'), findsWidgets);
    expect(find.text('UPI'), findsWidgets);
  });

  // The ladder's top rung reads `item_total` when the server sends it — the
  // deprecated `gross` alias only on an older backend — and its bottom rung is
  // Gross, off grand_total. The alias is set to a different number here purely
  // so the test can see which key the screen read.
  testWidgets('the money ladder: Item total from item_total, Gross from grand_total', (tester) async {
    final totals = {...(_salesSummary['totals'] as Map), 'item_total': 1900.0, 'gross': 1.0};
    final api = _FakeApi(extra: {
      '/reports/mis/sales-summary': {..._salesSummary, 'totals': totals},
    });
    await _mount(tester, api: api);
    await _openTab(tester, 'Sales Summary');
    final card = find.ancestor(of: find.text('Money ladder'), matching: find.byType(ForkCard)).first;
    Finder inCard(String s) => find.descendant(of: card, matching: find.text(s));
    expect(inCard('Item total'), findsOneWidget);
    expect(inCard('₹1900.00'), findsOneWidget);
    expect(inCard('₹1.00'), findsNothing, reason: 'the deprecated alias is not the rung when item_total is sent');
    expect(inCard('Gross'), findsOneWidget);
    expect(inCard('₹2000.00'), findsOneWidget);
    expect(inCard('Grand total'), findsNothing);
    // The tiles above it: GROSS is the grand total, NET the net.
    expect(find.descendant(of: find.ancestor(of: find.text('GROSS'), matching: find.byType(ForkCard)).first,
        matching: find.text('₹2000.00')), findsOneWidget);
    expect(find.descendant(of: find.ancestor(of: find.text('NET'), matching: find.byType(ForkCard)).first,
        matching: find.text('₹1800.00')), findsOneWidget);
  });

  testWidgets('unallocated settlement money is raised, not buried', (tester) async {
    final api = _FakeApi(extra: {'/reports/mis/settlement-summary': _settlementWithHole()});
    await _mount(tester, api: api);
    await _openTab(tester, 'Settlement Summary');
    expect(find.textContaining('Unallocated ₹45.50'), findsOneWidget);
  });

  testWidgets('the reports that cannot be reconciled say so on their own face', (tester) async {
    await _mount(tester);
    // Item Wise opens first: order-time basis, and a category recovered by name.
    expect(find.textContaining('does not tie to Sales Summary'), findsOneWidget);
    expect(find.textContaining('matched by dish NAME'), findsOneWidget);
    // The bill-level discount is reported rather than smeared across the lines.
    expect(find.text('BILL-LEVEL DISCOUNT'), findsOneWidget);

    await _openTab(tester, 'Void KOT');
    expect(find.textContaining('No KOT number exists'), findsOneWidget);

    await _openTab(tester, 'Bill Edit');
    expect(find.textContaining('No before/after amounts'), findsOneWidget);

    await _openTab(tester, 'Discount');
    expect(find.textContaining('reconstructed from the settled total'), findsOneWidget);
  });

  testWidgets("the server's own caveats are one tap away and named as such", (tester) async {
    await _mount(tester);
    await _openTab(tester, 'Sales Summary');
    await tester.tap(find.byKey(const ValueKey('reports-notes')));
    await tester.pumpAndSettle();
    expect(find.text('HOW THESE NUMBERS ARE COUNTED'), findsOneWidget);
    expect(find.textContaining('counted on the day they were SETTLED'), findsOneWidget);
    expect(find.textContaining('Round off is always 0'), findsOneWidget);
  });

  // ------------------------------------------------------------- exports ---

  testWidgets('an export carries the WHOLE window, not the page on screen', (tester) async {
    Uint8List? captured;
    String? name;
    ReportExporter.overrideDeliver = (bytes, filename, format) async {
      captured = bytes;
      name = filename;
      return const ReportExportResult('Saved');
    };
    await _mount(tester);
    await _openTab(tester, 'Discount');

    // The screen holds page one only.
    expect(find.text('101'), findsOneWidget);
    expect(find.text('103'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reports-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();

    final csv = utf8.decode(captured!);
    // Every row of the window, swept across the server's pages.
    expect(csv, contains('101'));
    expect(csv, contains('102'));
    expect(csv, contains('103'), reason: 'the export stopped at the page on screen');
    // Provenance: what, for whom, over what, in whose calendar.
    expect(csv, contains('Report,Discount'));
    expect(csv, contains('Kalyani Nagar'));
    expect(csv, contains('2026-08-01 to 2026-08-02 (both days included)'));
    expect(csv, contains('Asia/Kolkata'));
    // The server's caveats travel with the file.
    expect(csv, contains('How these numbers are counted'));
    expect(csv, contains('reconstructed from the settled total'));
    // Money as a NUMBER, so the column sums in a spreadsheet.
    expect(csv, contains('100.00'));
    expect(csv, isNot(contains('₹100.00')));
    // The totals row, labelled.
    expect(csv, contains('TOTAL (whole period)'));
    expect(name, 'discount_kalyani-nagar_2026-08-01_to_2026-08-02.csv');
  });

  testWidgets('the export carries exactly the columns on screen', (tester) async {
    Uint8List? captured;
    ReportExporter.overrideDeliver = (bytes, filename, format) async {
      captured = bytes;
      return const ReportExportResult('Saved');
    };
    await _mount(tester);
    await _openTab(tester, 'Discount');

    await tester.tap(find.byKey(const ValueKey('reports-columns')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reports-col-reason')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reports-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();

    final csv = utf8.decode(captured!);
    expect(csv, isNot(contains('Regular guest')), reason: 'a hidden column reached the file');
    expect(csv, isNot(contains(',Reason,')));
    expect(csv, contains('Bill No.'));
  });

  testWidgets('Excel and PDF render without throwing, and the sheet holds real numbers',
      (tester) async {
    final grabbed = <ReportFormat, Uint8List>{};
    ReportExporter.overrideDeliver = (bytes, filename, format) async {
      grabbed[format] = bytes;
      return const ReportExportResult('Saved');
    };
    await _mount(tester);
    await _openTab(tester, 'Settlement Summary');

    for (final label in const ['Export Excel', 'Export PDF']) {
      await tester.tap(find.byKey(const ValueKey('reports-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(grabbed[ReportFormat.excel], isNotNull);
    expect(grabbed[ReportFormat.excel]!.length, greaterThan(500));
    expect(grabbed[ReportFormat.pdf], isNotNull);
    // A PDF is a PDF.
    expect(utf8.decode(grabbed[ReportFormat.pdf]!.sublist(0, 5)), '%PDF-');
  });

  // "Item names should show up properly in the void KOT reports in the Excel."
  // The row always carried an `items` LIST, which is not a cell. The server now
  // sends the names as one text column; nothing on this side names that column,
  // so these prove it reaches the screen and both files purely because the
  // server declared it, and that the file reads the restaurant clock.
  testWidgets('Void KOT: the Items column reaches the screen, the CSV and the Excel as plain text',
      (tester) async {
    final grabbed = <ReportFormat, Uint8List>{};
    ReportExporter.overrideDeliver = (bytes, filename, format) async {
      grabbed[format] = bytes;
      return const ReportExportResult('Saved');
    };
    await _mount(tester);
    await _openTab(tester, 'Void KOT');
    expect(find.text('Paneer Tikka (Half) x2; Dal x1'), findsWidgets);

    for (final label in const ['Export CSV', 'Export Excel']) {
      await tester.tap(find.byKey(const ValueKey('reports-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    final csv = utf8.decode(grabbed[ReportFormat.csv]!);
    expect(csv, contains('KOT / Order,Table,Items,Type'));
    expect(csv, contains('order-9,T7,Paneer Tikka (Half) x2; Dal x1,Dine-in'));
    expect(csv, isNot(contains('{name:')), reason: 'the items list reached the file');
    // 12:00 UTC is 17:30 in Kolkata: the restaurant clock, year first.
    expect(csv, contains('2026-08-01 17:30,2026-08-01 17:39,order-9'));
    expect(csv, isNot(contains('2026-08-01T12:00:00.000Z')));
    expect(csv, isNot(contains('Aug 1, 17:30')), reason: 'a sheet cell with no year');

    final sheet = xl.Excel.decodeBytes(grabbed[ReportFormat.excel]!).tables['Report']!;
    final header = sheet.rows.firstWhere((r) => r.any((c) => '${c?.value}' == 'Items'));
    final itemsAt = header.indexWhere((c) => '${c?.value}' == 'Items');
    final placedAt = header.indexWhere((c) => '${c?.value}' == 'Placed');
    final row = sheet.rows.firstWhere((r) => r.any((c) => '${c?.value}' == 'order-9'));
    expect('${row[itemsAt]?.value}', 'Paneer Tikka (Half) x2; Dal x1');
    expect('${row[placedAt]?.value}', '2026-08-01 17:30');
    // AND IT OPENS READABLE. Excel spills text only into an EMPTY neighbour, and
    // Type is never empty, so a column at Excel's default of about eight
    // characters showed "Paneer T". The width is read back out of the file.
    expect(sheet.getColumnWidth(itemsAt), greaterThanOrEqualTo('Paneer Tikka (Half) x2; Dal x1'.length));
    expect(sheet.getColumnWidth(placedAt), greaterThanOrEqualTo('2026-08-01 17:30'.length));
  });

  // --------------------------------------------------------------- phone ---

  testWidgets('on a phone the table becomes a card per row, every value beside its own label',
      (tester) async {
    await _mount(tester, width: 390, height: 1400);
    await _openTab(tester, 'Order Summary');

    // The frozen-column grid is NOT used at this width.
    expect(find.byKey(const ValueKey('reports-grid')), findsNothing);
    expect(find.byKey(const ValueKey('reports-cards')), findsOneWidget);

    // Nothing is folded away: the labels travel with the values.
    expect(find.text('101'), findsWidgets);
    expect(find.text('BILL NO.'), findsWidgets);
    expect(find.text('WAITER'), findsWidgets);
    expect(find.text('Asha'), findsOneWidget);
    expect(find.text('TOTAL · WHOLE PERIOD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the phone layout keeps the whole shell — window, search, columns, export',
      (tester) async {
    await _mount(tester, width: 390, height: 1400);
    expect(find.byKey(const ValueKey('reports-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-columns')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-export')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone drill-down still opens the full bill', (tester) async {
    final api = await _mount(tester, width: 390, height: 1400);
    await _openTab(tester, 'Order Summary');
    await tester.tap(find.text('101').first);
    await tester.pumpAndSettle();
    expect(api.gets.any((c) => c.contains('/reports/mis/bill/')), isTrue);
  });

  // AN EMPTY PERIOD ON A PHONE WITH LARGE TEXT. The compact layout used to put
  // the empty state in a FIXED 280px box. At 1.3x on a 360dp phone the icon,
  // the title and a caption wrapped to several lines need more than that, so
  // the column overflowed: 26px in Rustic Fork, 57px in Gaia, whose type is
  // taller. 280 is a floor now, not a ceiling.
  for (final system in DesignSystem.values) {
    testWidgets('an empty period on a 360dp phone at 1.3x text fits its box (${system.label})',
        (tester) async {
      await _mount(
        tester,
        width: 360,
        height: 900,
        system: system,
        textScale: 1.3,
        api: _FakeApi(extra: {'/reports/mis/item-wise': _emptyItemWise}),
      );
      expect(find.byKey(const ValueKey('reports-cards')), findsNothing);

      // At 1.3x the summary tiles push the empty state below the fold, into the
      // list's cache area: built, but not painted — and an overflow is only
      // reported when it paints. So bring it on screen first, as a reader would.
      final empty = find.byType(EmptyState, skipOffstage: false);
      expect(empty, findsOneWidget);
      await tester.ensureVisible(empty);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(tester.getSize(empty).height, greaterThan(280),
          reason: 'at 1.3x the empty state needs more than the old 280');
      // Measured against the Column, not the padded EmptyState: an overflow
      // smaller than the 40px padding (Rustic's 26) still lands inside the
      // outer box, but never inside the Column that was squeezed.
      final content = tester.getRect(find.descendant(of: empty, matching: find.byType(Column)).first);
      final caption = tester.getRect(find.textContaining('Item Wise has no rows between'));
      expect(caption.bottom, lessThanOrEqualTo(content.bottom),
          reason: 'the caption runs past the bottom of its own column');
    }, variant: TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android}));
  }

  testWidgets('at normal text size the phone empty state keeps its 280px, and the desktop fills the pane',
      (tester) async {
    // Growing with the text must not change the look anyone already has: at 1x
    // the phone box is the same 280px it always was...
    await _mount(tester,
        width: 360, height: 900, api: _FakeApi(extra: {'/reports/mis/item-wise': _emptyItemWise}));
    expect(tester.getSize(find.byType(EmptyState, skipOffstage: false)).height, 280);

    // ...and the desktop never had the box: its empty state takes whatever the
    // pane leaves under the controls, as the grid would.
    await _mount(tester, api: _FakeApi(extra: {'/reports/mis/item-wise': _emptyItemWise}));
    expect(find.text('Nothing in this period'), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-grid')), findsNothing);
    expect(tester.getSize(find.byType(EmptyState)).height, greaterThan(280));
    expect(tester.takeException(), isNull);
  });

  // AN EMPTY PERIOD IN A MID-HEIGHT DESKTOP WINDOW. From 430px of pane the
  // desktop layout takes over, and Sales Summary's chrome fills its 45% cap, so
  // the slot left under the controls was shorter than the empty state itself:
  // 79px short at 680, 46 at 740 and 13 at 800 in Rustic Fork (89, 56 and 23 in
  // Gaia). The empty state now scrolls inside that slot instead of overflowing it.
  for (final system in DesignSystem.values) {
    for (final height in const <double>[680, 740, 800]) {
      testWidgets(
          'an empty Sales Summary in a 1400x${height.toInt()} window scrolls, not overflows (${system.label})',
          (tester) async {
        await _mount(tester,
            height: height,
            system: system,
            api: _FakeApi(extra: {'/reports/mis/sales-summary': _emptySalesSummary}));
        await _openTab(tester, 'Sales Summary');
        expect(tester.takeException(), isNull);
        // The desktop layout, not the phone's: only the compact list pulls to refresh.
        expect(find.byType(RefreshIndicator), findsNothing);

        final empty = find.byType(EmptyState);
        expect(empty, findsOneWidget);
        // Measured against the Column: squeezed, it is shorter than its own
        // caption; given room to scroll, it is exactly as tall as its content.
        final content = find.descendant(of: empty, matching: find.byType(Column)).first;
        final caption = find.textContaining('Sales Summary has no rows between');
        expect(tester.getRect(caption).bottom, lessThanOrEqualTo(tester.getRect(content).bottom),
            reason: 'the caption runs past the bottom of its own column');

        // And nothing is out of reach: the caption scrolls into the slot.
        await tester.ensureVisible(caption);
        await tester.pumpAndSettle();
        final slot = tester.getRect(find.ancestor(of: empty, matching: find.byType(Scrollable)).first);
        final seen = tester.getRect(caption);
        expect(seen.top, greaterThanOrEqualTo(slot.top));
        expect(seen.bottom, lessThanOrEqualTo(slot.bottom));
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant(<TargetPlatform>{TargetPlatform.windows, TargetPlatform.android}));
    }
  }

  // With room to spare nothing moves: the empty state is still the whole slot,
  // its content still centred in it, and there is nothing to scroll.
  for (final system in DesignSystem.values) {
    testWidgets('a desktop empty state with room still fills its slot, centred (${system.label})',
        (tester) async {
      await _mount(tester,
          height: 1000,
          system: system,
          api: _FakeApi(extra: {'/reports/mis/sales-summary': _emptySalesSummary}));
      await _openTab(tester, 'Sales Summary');
      expect(find.byType(RefreshIndicator), findsNothing);

      final empty = find.byType(EmptyState);
      final slot = find.ancestor(of: empty, matching: find.byType(Scrollable)).first;
      expect(tester.getRect(empty), tester.getRect(slot));
      expect(tester.state<ScrollableState>(slot).position.maxScrollExtent, 0);
      final content = tester.getRect(find.descendant(of: empty, matching: find.byType(Column)).first);
      expect(content.center.dy, closeTo(tester.getRect(empty).center.dy, 0.5));
      expect(tester.takeException(), isNull);
    });
  }

  // -------------------------------------------------------------- search ---

  testWidgets('search rides on the request, debounced so a keystroke is not a query',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Order Summary');
    final before = api.gets.length;

    await tester.enterText(find.byKey(const ValueKey('reports-search')), '101');
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.gets.length, before, reason: 'a keystroke fired a request');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(api.gets.last, contains('search=101'));
  });

  testWidgets('a docked desktop window degrades to cards rather than overflowing', (tester) async {
    // Sales Summary carries the tallest chrome in the pack — six tiles, the
    // money ladder and its caveats. In a short window a pinned-header grid
    // would be a header and a totals row with a sliver between them, so the
    // SAME degradation the phone uses applies: cards, nothing clipped.
    await _mount(tester, width: 900, height: 520);
    await _openTab(tester, 'Sales Summary');

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('reports-grid')), findsNothing);
    // At 520px the ladder may start just below the fold: since 2.0.2 the
    // Reports / Email reports switch (item 9) and the order-type split (item
    // 10) sit above it. It is reached by the same one ordinary scroll.
    await tester.scrollUntilVisible(find.text('Money ladder'), 100,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    expect(find.text('Money ladder'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The rows are below the fold of ONE ordinary vertical scroll — no pinned
    // header fighting for the same pixels, nothing clipped.
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reports-cards')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full-height desktop window keeps the pinned-header grid', (tester) async {
    await _mount(tester, width: 900, height: 900);
    await _openTab(tester, 'Sales Summary');
    expect(find.byKey(const ValueKey('reports-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-cards')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the search field can be cleared on the first keystroke', (tester) async {
    await _mount(tester);
    expect(find.byTooltip('Clear search'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('reports-search')), '1');
    await tester.pump();
    // The affordance arrives immediately; the QUERY still waits out the debounce.
    expect(find.byTooltip('Clear search'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clear search'), findsNothing);
  });

  // A report whose endpoint reads no search drops the term, box and all: a
  // word left in the box would filter nothing, and the empty state would go on
  // to blame it. The box is only built for the searchable reports, so what
  // empties it is `_setTab` clearing the screen's controller while the box can
  // still hear it. Without that, the next searchable report showed the old
  // word, x and all, over a report that was not filtered by it.
  final searchBox = find.byKey(const ValueKey('reports-search'));
  String boxText(WidgetTester tester) =>
      tester.widget<EditableText>(find.descendant(of: searchBox, matching: find.byType(EditableText))).controller.text;
  String lastOrderSummary(_FakeApi api) =>
      api.gets.lastWhere((g) => g.contains('/reports/mis/order-summary'), orElse: () => '');

  testWidgets('a report that reads no search drops the term: back on a searchable one, the box is empty',
      (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Order Summary');
    await tester.enterText(searchBox, '101');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(lastOrderSummary(api), contains('search=101'));

    await _openTab(tester, 'Sales Summary');
    expect(searchBox, findsNothing, reason: 'Sales Summary reads no search');
    await _openTab(tester, 'Order Summary');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(boxText(tester), isEmpty, reason: 'the dropped term came back in the box');
    expect(find.byTooltip('Clear search'), findsNothing);
    expect(lastOrderSummary(api), isNot(contains('search=')));
  }, variant: searchPlatforms);

  testWidgets('a term still waiting out the debounce is dropped by the tab change too', (tester) async {
    final api = await _mount(tester);
    await _openTab(tester, 'Order Summary');
    final sales = find.text('Sales Summary').first;
    await tester.ensureVisible(sales);
    await tester.pumpAndSettle();
    final before = api.gets.length;

    await tester.enterText(searchBox, '101');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(sales);
    await tester.pump();
    expect(searchBox, findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    await _openTab(tester, 'Order Summary');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(boxText(tester), isEmpty);
    expect(find.byTooltip('Clear search'), findsNothing);
    expect(api.gets.skip(before).where((g) => g.contains('search=')), isEmpty,
        reason: 'the word typed before the tab change was sent after it');
  }, variant: searchPlatforms);

  // CLIENT ITEM 6 (2.0.2): the MIS search is one of the app's registered search
  // boxes (test/search_clear_registry_test.dart). Its contract row lives here,
  // beside the fixtures it needs: the x, pressed where it is drawn, must send
  // the next report request without `search=`.
  searchContractRows('reports-search', (tester, ds) async {
    await tester.pumpWidget(const SizedBox());
    useSearchView(tester, onPhone ? null : const Size(1400, 1000));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fake = _FakeApi();
    final auth = AuthController(api: fake);
    await auth.login('CSR Organics', 'admin', 'admin123');
    await tester.pumpWidget(searchThemed(
      ds,
      ModuleNavigator(
        openModule: (_, {Map<String, dynamic>? target}) {},
        visibleLabels: const ['Reports', 'History', 'Accounting'],
        clearFocus: () {},
        switchOutlet: (_) {},
        child: Scaffold(backgroundColor: Colors.transparent, body: m.reportsModule(RestClient(auth), auth.profile!)),
      ),
    ));
    await tester.pumpAndSettle();
    // The report it opens on reads a search (Gaia spells the tab names its own
    // way, so the row does not go looking for one).
    return SearchSurface(
      field: find.byKey(const ValueKey('reports-search')),
      typed: '101',
      filtered: () => fake.gets.lastWhere((g) => g.contains('/reports/mis/')).contains('search='),
    );
  });

  // ------------------------------------------------- pure export rendering --

  group('report_export (pure)', () {
    const money = MisColumn(key: 'net', label: 'Net', type: 'money', total: true);
    const pct = MisColumn(key: 'share_pct', label: 'Share', type: 'percent');
    const count = MisColumn(key: 'bills', label: 'Bills', type: 'int', total: true);
    const text = MisColumn(key: 'method', label: 'Mode', type: 'text');

    test('one formatter, three surfaces, one deliberate difference', () {
      expect(misText(money, 1234.5), '₹1234.50');
      expect(misText(money, 1234.5, forPdf: true), 'Rs 1234.50',
          reason: 'the PDF font has no rupee glyph');
      expect(misText(money, 1234.5, forSheet: true), '1234.50',
          reason: 'a sheet must be able to sum the column');
      expect(misText(pct, 12.34), '12.3%');
      expect(misText(count, 7.0), '7');
    });

    test('a null is an em dash on screen and an empty cell in a sheet — never a zero', () {
      expect(misText(money, null), '—');
      expect(misText(money, null, forSheet: true), '');
      expect(misText(pct, null), '—');
      expect(misText(text, null), '—');
    });

    test('an instant is the restaurant clock everywhere, and year first in a sheet', () {
      // Generic by column TYPE: any report's datetime column, no key named.
      const at = MisColumn(key: 'whenever', label: 'When', type: 'datetime');
      const iso = '2026-09-14T13:06:36.104Z';
      final screen = misText(at, iso);
      expect(screen, RestaurantTime.short(iso));
      expect(misText(at, iso, forPdf: true), screen);
      // The sheet is not the screen's "Sep 14, 18:36": no year, and as text it
      // sorts Sep 14 before Sep 2.
      expect(misText(at, iso, forSheet: true), '2026-09-14 18:36', reason: 'the sheet carried the raw UTC instant or a yearless stamp');
      expect(misText(at, null, forSheet: true), '', reason: 'a blank stays a blank');
      // Not an instant: kept as sent, never blanked.
      expect(misText(at, 'not-a-date', forSheet: true), 'not-a-date');
    });

    test('a sheet stamp sorts in date order as plain text, across a month and a year', () {
      const at = MisColumn(key: 'whenever', label: 'When', type: 'datetime');
      const instants = ['2026-09-02T04:30:00.000Z', '2026-09-14T04:30:00.000Z', '2025-09-14T04:30:00.000Z', '2026-10-01T04:30:00.000Z'];
      final byText = [for (final i in instants) misText(at, i, forSheet: true)]..sort();
      final byInstant = ([...instants]..sort()).map((i) => misText(at, i, forSheet: true)).toList();
      expect(byText, byInstant);
    });

    test('the owner app and the web write the same sheet string for the same instant and zone', () {
      // THE SAME TABLE is pinned in the web dashboard's
      // src/lib/__tests__/mis-reports.test.ts (formatSheetDateTime). Change one
      // and the other fails.
      const parity = [
        ['2026-09-14T13:06:36.104Z', 'Asia/Kolkata', '2026-09-14 18:36'],
        ['2026-09-14T18:30:00.000Z', 'Asia/Kolkata', '2026-09-15 00:00'],
        ['2026-01-15T17:00:00.000Z', 'America/New_York', '2026-01-15 12:00'],
        ['2026-07-15T17:00:00.000Z', 'America/New_York', '2026-07-15 13:00'],
      ];
      SharedPreferences.setMockInitialValues(<String, Object>{});
      addTearDown(() => RestaurantTime.adopt(RestaurantTime.defaultZone));
      for (final row in parity) {
        RestaurantTime.adopt(row[1]);
        expect(RestaurantTime.sheet(row[0]), row[2], reason: '${row[0]} in ${row[1]}');
      }
    });

    test('every sheet column is as wide as its widest cell, which Excel does not do for itself', () {
      // A real ticket from the client's own day of voids (14 Sep), 115 characters.
      const long = 'BOTTLE WATER x1; CRISP WRAPPED COTTAGE CHEESE x1; BAINGAN BHARTHA KULCHA x1; ENOKII TEMPURA x1; HOUSE FRIED RICE x1';
      const items = MisColumn(key: 'items_text', label: 'Items', type: 'text');
      const kind = MisColumn(key: 'order_type', label: 'Type', type: 'text');
      final doc = MisReportDoc(
        title: 'Void KOT',
        columns: const [count, items, kind, money],
        rows: const [
          {'bills': 1, 'items_text': 'CANNED JUICE x1', 'order_type': 'dine_in', 'net': 225.0},
          {'bills': 1, 'items_text': long, 'order_type': 'dine_in', 'net': 1234567.5},
        ],
        totals: const {'bills': 2, 'net': 1234792.5},
        from: '2026-09-14',
        to: '2026-09-14',
        timezone: 'Asia/Kolkata',
        outletLabel: 'Gaia',
        // A long note in the preamble must not widen the table's first column.
        notes: ['n' * 300],
      );
      expect(misSheetColumnWidths(doc), [
        'TOTAL (whole period)'.length + 2,
        long.length + 2,
        misSheetMinWidth,
        '1234792.50'.length + 2,
      ]);
      final sheet = xl.Excel.decodeBytes(misXlsx(doc)).tables['Report']!;
      final header = sheet.rows.firstWhere((r) => r.any((c) => '${c?.value}' == 'Items'));
      final itemsAt = header.indexWhere((c) => '${c?.value}' == 'Items');
      expect(sheet.getColumnWidth(itemsAt), greaterThanOrEqualTo(long.length));
      // Nothing past Excel's own limit, however long a cell is.
      final huge = MisReportDoc(
        title: 'X', columns: const [items], rows: [{'items_text': 'y' * 400}], totals: null,
        from: '2026-09-14', to: '2026-09-14', timezone: 'Asia/Kolkata', outletLabel: 'Gaia', notes: const [],
      );
      expect(misSheetColumnWidths(huge), [misSheetMaxWidth]);
      expect(misSheetMaxWidth, lessThan(255));
    });

    test('the CSV opens with its own provenance and closes with the window totals', () {
      const doc = MisReportDoc(
        title: 'Settlement Summary',
        columns: [text, count, money],
        rows: [
          {'method': 'Cash', 'bills': 1, 'net': 1200.0},
          {'method': 'UPI, split', 'bills': 1, 'net': 800.0},
        ],
        totals: {'bills': 2, 'net': 2000.0},
        from: '2026-08-01',
        to: '2026-08-02',
        timezone: 'Asia/Kolkata',
        outletLabel: 'Kalyani Nagar',
        notes: ['Refunds are shown, not netted off.'],
      );
      final csv = misCsv(doc);
      expect(csv, startsWith('Report,Settlement Summary\r\n'));
      expect(csv, contains('Outlet,Kalyani Nagar'));
      expect(csv, contains('Timezone,Asia/Kolkata'));
      expect(csv, contains('Refunds are shown, not netted off.'));
      // A comma inside a value is quoted, not a new column.
      expect(csv, contains('"UPI, split"'));
      expect(csv, contains('TOTAL (whole period),2,2000.00'));
      expect(doc.fileStem, 'settlement-summary_kalyani-nagar_2026-08-01_to_2026-08-02');
    });

    test('a column the server does not sum gets no total, ever', () {
      const doc = MisReportDoc(
        title: 'Cover Size Summary',
        columns: [
          MisColumn(key: 'party_size', label: 'Party size', type: 'int'),
          MisColumn(key: 'bills', label: 'Bills', type: 'int', total: true),
        ],
        rows: [
          {'party_size': 2, 'bills': 1},
          {'party_size': 3, 'bills': 1},
        ],
        totals: {'party_size': 5, 'bills': 2},
        from: '2026-08-01',
        to: '2026-08-02',
        timezone: 'Asia/Kolkata',
        outletLabel: 'All outlets',
        notes: [],
      );
      // `party_size` is the frozen first column, so it carries the label; the
      // 5 the payload happens to hold under it must never be printed.
      expect(misCsv(doc), contains('TOTAL (whole period),2'));
      expect(misCsv(doc), isNot(contains('TOTAL (whole period),5')));
    });

    test('an export that could not sweep the whole window says so on its own face', () {
      const doc = MisReportDoc(
        title: 'Discount',
        columns: [text],
        rows: [{'method': 'Cash'}],
        totals: null,
        from: '2026-08-01',
        to: '2026-08-02',
        timezone: 'Asia/Kolkata',
        outletLabel: 'Kalyani Nagar',
        notes: [],
        truncatedAt: 10000,
      );
      expect(misCsv(doc), contains('truncated at 10000'));
    });

    test('the PDF is folded to what its font can actually draw', () {
      // dart_pdf's built-in Helvetica has no Unicode coverage: an unfolded
      // rupee sign or em dash does not render as a wrong glyph, it renders as
      // NOTHING — a money column that quietly loses its currency, or a blank
      // cell that loses its dash.
      expect(pdfSafe('₹1,234.00'), 'Rs 1,234.00');
      expect(pdfSafe('Bill #101 · T1 — void'), 'Bill #101 - T1 - void');
      expect(pdfSafe('Order → Cancelled'), 'Order -> Cancelled');
      expect(pdfSafe("don’t “void”…"), "don't \"void\"...");
      // Anything still outside Latin-1 is marked, not dropped.
      expect(pdfSafe('你好'), '??');
      // ASCII is untouched.
      expect(pdfSafe('TOTAL (whole period)'), 'TOTAL (whole period)');
    });

    test('the column descriptor is read exactly as the server writes it', () {
      final cols = MisColumn.listOf([
        {'key': 'a', 'label': 'A', 'type': 'money', 'total': true},
        {'key': 'b', 'label': 'B', 'type': 'text', 'default_on': false},
        {'key': 'c', 'label': 'C', 'type': 'percent'},
      ]);
      expect(cols.map((c) => c.key).toList(), ['a', 'b', 'c']);
      expect(cols[0].total, isTrue);
      expect(cols[0].isNumeric, isTrue);
      expect(cols[1].defaultOn, isFalse);
      expect(cols[2].defaultOn, isTrue, reason: 'absent default_on means ON');
      expect(cols[2].total, isFalse);
    });
  });
}
